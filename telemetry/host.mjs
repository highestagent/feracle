#!/usr/bin/env node

import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseCliArgs } from "./cli.mjs";
import {
  INITIAL_LOG_LOOKBACK,
  MAX_FRAME_SEQS,
  MAX_LOG_BLOCK_SPAN,
  MAX_ROUND_TX_COUNTS,
  MAX_SEEN_RECEIPTS,
  MEDIANS_SUBMITTED_TOPIC,
  addBoundedSet,
  createFrameDeduper,
  createSettlementIndexer,
  setBoundedMap,
  shouldSkipStatusPoll,
} from "./indexer.mjs";
import { WasmTelemetryHost, rpcJsonCall } from "./wasm_bridge.mjs";

export {
  INITIAL_LOG_LOOKBACK,
  MAX_FRAME_SEQS,
  MAX_LOG_BLOCK_SPAN,
  MAX_ROUND_TX_COUNTS,
  MAX_SEEN_RECEIPTS,
  MEDIANS_SUBMITTED_TOPIC,
  addBoundedSet,
  createFrameDeduper,
  createSettlementIndexer,
  setBoundedMap,
  shouldSkipStatusPoll,
  parseCliArgs,
};

async function main() {
  const opts = parseCliArgs(process.argv.slice(2));
  const wasmHost = WasmTelemetryHost.load(opts.wasm);
  wasmHost.configure(opts.contract, opts.oracles);

  const frameDeduper = createFrameDeduper({
    nodeCount: opts.nodeUrls.length,
    ingestWireFrame: (hex, canonicalPeer, isTx) =>
      wasmHost.ingestWireFrame(hex, canonicalPeer, isTx),
  });
  const settlementIndexer = createSettlementIndexer({
    rpcCall: (bodyObj) => rpcJsonCall(opts.rpcUrl, bodyObj),
    contract: opts.contract,
    ingestTx: (roundId, blockNum, gasUsed, nextCount, from) =>
      wasmHost.ingestTx(roundId, blockNum, gasUsed, nextCount, from),
  });
  const sseConnected = opts.nodeUrls.map(() => false);
  const sseLastEventAt = opts.nodeUrls.map(() => 0);
  let stopping = false;

  async function pollRpcAndBlocks() {
    const batchBody = wasmHost.buildRpcBatch();
    const t0 = performance.now();
    try {
      const resp = await fetch(opts.rpcUrl, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: batchBody,
        signal: AbortSignal.timeout(4000),
      });
      const text = await resp.text();
      const latencyMs = Math.max(0, Math.round(performance.now() - t0));
      if (!resp.ok) {
        return;
      }
      wasmHost.ingestRpc(text, latencyMs);

      let parsed;
      try {
        parsed = JSON.parse(text);
      } catch {
        return;
      }
      const items = Array.isArray(parsed) ? parsed : [parsed];
      const blockItem = items.find((x) => x && x.id === 2 && typeof x.result === "string");
      if (!blockItem) {
        return;
      }
      const latestBlock = Number(BigInt(blockItem.result));
      await settlementIndexer.processLatestBlock(latestBlock);
    } catch {
      // Transient RPC disconnect; next interval will retry cleanly
    }
  }

  async function pollNodeStatuses() {
    const now = Date.now();
    await Promise.all(
      opts.nodeUrls.map(async (baseUrl, idx) => {
        if (shouldSkipStatusPoll(sseConnected[idx], sseLastEventAt[idx], now)) {
          return;
        }
        try {
          const resp = await fetch(`${baseUrl}/status`, {
            signal: AbortSignal.timeout(2000),
          });
          if (!resp.ok) {
            wasmHost.markNodeOffline(idx);
            return;
          }
          const body = await resp.text();
          try {
            const parsed = JSON.parse(body);
            if (parsed && parsed.peer_id) {
              frameDeduper.updatePeerId(idx, parsed.peer_id);
            }
            if (Array.isArray(parsed?.recent_frames)) {
              for (const frame of parsed.recent_frames) {
                frameDeduper.recordFrameOnce(idx, frame);
              }
            }
          } catch {
            // Let WASM report parse rejection if malformed
          }
          wasmHost.ingestNodeStatus(idx, body);
        } catch {
          wasmHost.markNodeOffline(idx);
        }
      })
    );
  }

  const sseAbortControllers = [];
  function startSseStream(nodeIdx, baseUrl) {
    (async () => {
      while (!stopping) {
        const controller = new AbortController();
        sseAbortControllers[nodeIdx] = controller;
        try {
          const resp = await fetch(`${baseUrl}/events`, {
            headers: { accept: "text/event-stream" },
            signal: controller.signal,
          });
          if (!resp.ok || !resp.body) {
            sseConnected[nodeIdx] = false;
            wasmHost.markNodeOffline(nodeIdx);
            await new Promise((r) => setTimeout(r, 500));
            continue;
          }
          sseConnected[nodeIdx] = true;
          sseLastEventAt[nodeIdx] = Date.now();
          const reader = resp.body.getReader();
          const decoder = new TextDecoder("utf-8");
          let buf = "";
          while (!stopping) {
            const { value, done } = await reader.read();
            if (done) {
              sseConnected[nodeIdx] = false;
              break;
            }
            buf += decoder.decode(value, { stream: true });
            let nlIdx;
            while ((nlIdx = buf.indexOf("\n")) !== -1) {
              const line = buf.slice(0, nlIdx).replace(/\r$/, "");
              buf = buf.slice(nlIdx + 1);
              if (!line.startsWith("data:")) {
                continue;
              }
              const payload = line.slice(5).trim();
              if (!payload) {
                continue;
              }
              try {
                const ev = JSON.parse(payload);
                sseLastEventAt[nodeIdx] = Date.now();
                if (ev.event === "status") {
                  if (ev.peer_id) {
                    frameDeduper.updatePeerId(nodeIdx, ev.peer_id);
                  }
                  if (Array.isArray(ev.recent_frames)) {
                    for (const frame of ev.recent_frames) {
                      frameDeduper.recordFrameOnce(nodeIdx, frame);
                    }
                  }
                  wasmHost.ingestNodeStatus(nodeIdx, payload);
                } else if (ev.event === "frame") {
                  frameDeduper.recordFrameOnce(nodeIdx, ev);
                }
              } catch {
                // Ignore non-JSON comments/partial lines
              }
            }
          }
        } catch {
          sseConnected[nodeIdx] = false;
          if (!stopping) {
            wasmHost.markNodeOffline(nodeIdx);
          }
        }
        sseConnected[nodeIdx] = false;
        if (!stopping) {
          await new Promise((r) => setTimeout(r, 500));
        }
      }
    })();
  }

  function renderOutput() {
    if (opts.mode === "json") {
      return wasmHost.renderJson() + "\n";
    }
    if (opts.mode === "prometheus") {
      return wasmHost.renderPrometheus();
    }
    return wasmHost.renderTui(opts.ansi);
  }

  let server = null;
  if (opts.metricsPort > 0 && !opts.once) {
    server = http.createServer((req, res) => {
      const urlPath = (req.url || "/").split("?")[0];
      try {
        if (urlPath === "/metrics") {
          const body = wasmHost.renderPrometheus();
          res.writeHead(200, { "content-type": "text/plain; version=0.0.4; charset=utf-8" });
          res.end(body);
          return;
        }
        if (urlPath === "/status") {
          const body = wasmHost.renderJson();
          res.writeHead(200, { "content-type": "application/json" });
          res.end(body);
          return;
        }
      } catch (err) {
        res.writeHead(500, { "content-type": "text/plain" });
        res.end(String(err));
        return;
      }
      res.writeHead(404, { "content-type": "text/plain" });
      res.end("Not Found\n");
    });
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(opts.metricsPort, "127.0.0.1", resolve);
    });
  }

  const cleanup = () => {
    if (stopping) {
      return;
    }
    stopping = true;
    for (const c of sseAbortControllers) {
      try {
        c?.abort();
      } catch {}
    }
    if (server) {
      try {
        server.close();
      } catch {}
    }
    wasmHost.close();
  };

  process.on("SIGINT", () => {
    cleanup();
    process.exit(0);
  });
  process.on("SIGTERM", () => {
    cleanup();
    process.exit(0);
  });

  if (opts.once) {
    await Promise.all([pollRpcAndBlocks(), pollNodeStatuses()]);
    process.stdout.write(renderOutput());
    cleanup();
    return;
  }

  opts.nodeUrls.forEach((url, idx) => startSseStream(idx, url));
  let busy = false;
  const tick = async () => {
    if (stopping || busy) {
      return;
    }
    busy = true;
    try {
      await Promise.all([pollRpcAndBlocks(), pollNodeStatuses()]);
      if (!stopping) {
        process.stdout.write(renderOutput());
      }
    } finally {
      busy = false;
    }
  };

  await tick();
  const timer = setInterval(tick, opts.intervalMs);
  if (stopping) {
    clearInterval(timer);
  }
}

export function isDirectEntrypoint(argv1, moduleUrl) {
  if (!argv1) {
    return false;
  }
  const resolveCanonical = (target) => {
    try {
      return fs.realpathSync(target);
    } catch {
      return path.resolve(target);
    }
  };
  return resolveCanonical(argv1) === resolveCanonical(fileURLToPath(moduleUrl));
}

if (isDirectEntrypoint(process.argv[1], import.meta.url)) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
