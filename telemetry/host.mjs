#!/usr/bin/env node

import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..");

const DEFAULT_RPC_URL = "http://127.0.0.1:8545";
const DEFAULT_ORACLES = [
  "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
  "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
].join(",");
const DEFAULT_WASM_PATH = path.join(REPO_ROOT, "out", "telemetry_wasm.wasm");
const SUBMIT_MEDIANS_SELECTOR = "0x6d2b8b3f";

function printHelp() {
  console.log(`Feracle WASM Telemetry Host (Node.js)

Usage: node telemetry/host.mjs [OPTIONS]

Options:
  --rpc-url <URL>        EVM JSON-RPC endpoint URL [env: ORACLE_RPC_URL] [default: ${DEFAULT_RPC_URL}]
  --contract <ADDR>      Deployed OffchainMedianOracle address (required) [env: ORACLE_CONTRACT]
  --oracles <CSV>        Comma-separated oracle addresses (up to 3) [env: ORACLE_ORACLES]
  --nodes <CSV>          Optional comma-separated node telemetry URLs (e.g. http://127.0.0.1:9101,...)
  --wasm <PATH>          Path to compiled Fe WASM module [default: ${DEFAULT_WASM_PATH}]
  --interval-ms <MS>     Poll & refresh interval in milliseconds [default: 1000]
  --mode <MODE>          Output mode: tui | json | prometheus [default: tui]
  --once                 Run one collection cycle, print output once, and exit
  --no-ansi              Disable ANSI clear-screen and color escapes in TUI mode
  --metrics-port <PORT>  Optional HTTP port serving /metrics (Prometheus) and /status (JSON)
  -h, --help             Print help
`);
}

function parseCliArgs(argv) {
  const opts = {
    rpcUrl: process.env.ORACLE_RPC_URL || DEFAULT_RPC_URL,
    contract: process.env.ORACLE_CONTRACT || "",
    oracles: process.env.ORACLE_ORACLES || DEFAULT_ORACLES,
    nodes: process.env.ORACLE_NODES || "",
    wasm: process.env.ORACLE_WASM || DEFAULT_WASM_PATH,
    intervalMs: 1000,
    mode: "tui",
    once: false,
    ansi: Boolean(process.stdout.isTTY),
    metricsPort: 0,
  };

  let explicitAnsi = false;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "-h" || arg === "--help") {
      printHelp();
      process.exit(0);
    } else if (arg === "--once") {
      opts.once = true;
    } else if (arg === "--no-ansi") {
      opts.ansi = false;
      explicitAnsi = true;
    } else if (arg === "--ansi") {
      opts.ansi = true;
      explicitAnsi = true;
    } else if (arg === "--rpc-url" && i + 1 < argv.length) {
      opts.rpcUrl = argv[++i];
    } else if (arg.startsWith("--rpc-url=")) {
      opts.rpcUrl = arg.slice("--rpc-url=".length);
    } else if (arg === "--contract" && i + 1 < argv.length) {
      opts.contract = argv[++i];
    } else if (arg.startsWith("--contract=")) {
      opts.contract = arg.slice("--contract=".length);
    } else if (arg === "--oracles" && i + 1 < argv.length) {
      opts.oracles = argv[++i];
    } else if (arg.startsWith("--oracles=")) {
      opts.oracles = arg.slice("--oracles=".length);
    } else if (arg === "--nodes" && i + 1 < argv.length) {
      opts.nodes = argv[++i];
    } else if (arg.startsWith("--nodes=")) {
      opts.nodes = arg.slice("--nodes=".length);
    } else if (arg === "--wasm" && i + 1 < argv.length) {
      opts.wasm = argv[++i];
    } else if (arg.startsWith("--wasm=")) {
      opts.wasm = arg.slice("--wasm=".length);
    } else if (arg === "--interval-ms" && i + 1 < argv.length) {
      opts.intervalMs = Number(argv[++i]);
    } else if (arg.startsWith("--interval-ms=")) {
      opts.intervalMs = Number(arg.slice("--interval-ms=".length));
    } else if (arg === "--mode" && i + 1 < argv.length) {
      opts.mode = argv[++i];
    } else if (arg.startsWith("--mode=")) {
      opts.mode = arg.slice("--mode=".length);
    } else if (arg === "--metrics-port" && i + 1 < argv.length) {
      opts.metricsPort = Number(argv[++i]);
    } else if (arg.startsWith("--metrics-port=")) {
      opts.metricsPort = Number(arg.slice("--metrics-port=".length));
    } else {
      console.error(`Unknown or incomplete option: ${arg}`);
      process.exit(2);
    }
  }

  if (opts.once && !explicitAnsi) {
    opts.ansi = false;
  }
  if (!opts.contract) {
    console.error("Missing required --contract <ADDR> (or ORACLE_CONTRACT)");
    process.exit(2);
  }
  if (!["tui", "json", "prometheus"].includes(opts.mode)) {
    console.error(`Invalid --mode '${opts.mode}' (expected tui, json, or prometheus)`);
    process.exit(2);
  }
  if (!Number.isFinite(opts.intervalMs) || opts.intervalMs < 100) {
    console.error("Invalid --interval-ms (must be >= 100)");
    process.exit(2);
  }

  opts.nodeUrls = opts.nodes
    .split(",")
    .map((s) => s.trim().replace(/\/+$/, ""))
    .filter(Boolean);

  return opts;
}

class WasmTelemetryHost {
  constructor(instance) {
    this.instance = instance;
    this.exports = instance.exports;
    this.decoder = new TextDecoder("utf-8");
    this.encoder = new TextEncoder();
    this.stdoutChunks = [];
    this.handle = this.exports.telemetry_new();
    if (!this.handle) {
      throw new Error("telemetry_new returned null handle");
    }
  }

  static load(wasmPath) {
    const bytes = fs.readFileSync(wasmPath);
    const mod = new WebAssembly.Module(bytes);
    let hostRef = null;
    const decoder = new TextDecoder("utf-8");

    const instance = new WebAssembly.Instance(mod, {
      env: {
        __fe_revert(addr, len) {
          const mem = new Uint8Array(instance.exports.memory.buffer, addr >>> 0, len >>> 0);
          const hex = Buffer.from(mem).toString("hex");
          throw new Error(`Fe WASM revert (${len} bytes): 0x${hex}`);
        },
        sys_wasm_now_ms() {
          return BigInt(Date.now());
        },
        sys_wasm_stream_write(stream, addr, len) {
          const slice = new Uint8Array(instance.exports.memory.buffer, addr >>> 0, len >>> 0);
          if (stream === 1 && hostRef) {
            hostRef.stdoutChunks.push(Buffer.from(slice));
            return len;
          }
          if (stream === 2) {
            process.stderr.write(decoder.decode(slice));
            return len;
          }
          return -1;
        },
        sys_wasm_log_i32(val) {
          process.stderr.write(`[wasm log_i32] ${val}\n`);
        },
        sys_wasm_log_u64(val) {
          process.stderr.write(`[wasm log_u64] ${val}\n`);
        },
        sys_wasm_abort(code) {
          throw new Error(`Fe WASM abort(${code})`);
        },
      },
    });

    const host = new WasmTelemetryHost(instance);
    hostRef = host;
    return host;
  }

  _unpackReply(word) {
    const u64 = BigInt.asUintN(64, word);
    const tag = Number(u64 & 0xffffffffn);
    const payload = Number((u64 >> 32n) & 0xffffffffn);
    return { tag, payload };
  }

  _withTexts(strings, fn) {
    const { arena_mark, arena_release, alloc } = this.exports;
    const mark = arena_mark();
    try {
      const pairs = strings.map((str) => {
        const encoded = this.encoder.encode(str);
        const ptr = encoded.length === 0 ? 0 : alloc(encoded.length);
        if (encoded.length > 0) {
          new Uint8Array(this.exports.memory.buffer, ptr >>> 0, encoded.length).set(encoded);
        }
        return [ptr, encoded.length];
      });
      return fn(pairs);
    } finally {
      arena_release(mark);
    }
  }

  _captureStdout(fn) {
    this.stdoutChunks = [];
    const word = fn();
    const { tag, payload } = this._unpackReply(word);
    if (tag !== 0) {
      throw new Error(`WASM call failed with Reply error tag=${tag}`);
    }
    const text = Buffer.concat(this.stdoutChunks).toString("utf-8");
    this.stdoutChunks = [];
    return { payload, text };
  }

  configure(contractHex, oraclesCsv) {
    const word = this._withTexts([contractHex, oraclesCsv], ([[cPtr, cLen], [oPtr, oLen]]) =>
      this.exports.telemetry_configure(this.handle, cPtr, cLen, oPtr, oLen)
    );
    const { tag } = this._unpackReply(word);
    if (tag !== 0) {
      throw new Error(`telemetry_configure failed tag=${tag}`);
    }
  }

  buildRpcBatch() {
    return this._captureStdout(() => this.exports.telemetry_build_rpc_batch(this.handle)).text;
  }

  ingestRpc(payload, latencyMs) {
    const word = this._withTexts([payload], ([[pPtr, pLen]]) =>
      this.exports.telemetry_ingest_rpc(
        this.handle,
        pPtr,
        pLen,
        BigInt(Math.max(0, Math.trunc(latencyMs)))
      )
    );
    return this._unpackReply(word).tag === 0;
  }

  ingestTx(roundId, blockNum, gasUsed, txCount, submitterHex) {
    const word = this._withTexts([submitterHex], ([[sPtr, sLen]]) =>
      this.exports.telemetry_ingest_tx(
        this.handle,
        BigInt(roundId),
        BigInt(blockNum),
        BigInt(gasUsed),
        txCount >>> 0,
        sPtr,
        sLen
      )
    );
    return this._unpackReply(word).tag === 0;
  }

  ingestWireFrame(frameHex, peerTag, isTx) {
    const word = this._withTexts([frameHex, peerTag || ""], ([[fPtr, fLen], [pPtr, pLen]]) =>
      this.exports.telemetry_ingest_wire_frame(
        this.handle,
        fPtr,
        fLen,
        pPtr,
        pLen,
        isTx ? 1 : 0
      )
    );
    return this._unpackReply(word).tag === 0;
  }

  ingestNodeStatus(nodeId, payload) {
    const word = this._withTexts([payload], ([[pPtr, pLen]]) =>
      this.exports.telemetry_ingest_node_status(this.handle, nodeId >>> 0, pPtr, pLen)
    );
    return this._unpackReply(word).tag === 0;
  }

  markNodeOffline(nodeId) {
    const word = this.exports.telemetry_mark_node_offline(this.handle, nodeId >>> 0);
    return this._unpackReply(word).tag === 0;
  }

  renderTui(ansi) {
    return this._captureStdout(() =>
      this.exports.telemetry_render_tui(this.handle, ansi ? 1 : 0)
    ).text;
  }

  renderJson() {
    return this._captureStdout(() => this.exports.telemetry_render_json(this.handle)).text;
  }

  renderPrometheus() {
    return this._captureStdout(() => this.exports.telemetry_render_prometheus(this.handle)).text;
  }

  close() {
    if (this.handle) {
      this.exports.telemetry_free(this.handle);
      this.handle = 0;
    }
  }
}

async function rpcJsonCall(rpcUrl, bodyObj) {
  const resp = await fetch(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(bodyObj),
    signal: AbortSignal.timeout(4000),
  });
  if (!resp.ok) {
    throw new Error(`RPC HTTP ${resp.status}`);
  }
  return resp.json();
}

async function main() {
  const opts = parseCliArgs(process.argv.slice(2));
  const wasmHost = WasmTelemetryHost.load(opts.wasm);
  wasmHost.configure(opts.contract, opts.oracles);

  const contractLower = opts.contract.toLowerCase();
  const nodePeerIds = new Array(opts.nodeUrls.length).fill(null);
  const seenSeqs = opts.nodeUrls.map(() => new Set());
  const seenReceipts = new Set();
  const roundTxCounts = new Map();
  let lastScannedBlock = null;
  let stopping = false;

  function recordFrameOnce(nodeIdx, frame) {
    if (!frame || !frame.hex || typeof frame.seq !== "number") {
      return;
    }
    const set = seenSeqs[nodeIdx];
    if (set.has(frame.seq)) {
      return;
    }
    if (set.size > 512) {
      const oldest = set.values().next().value;
      set.delete(oldest);
    }
    set.add(frame.seq);
    const canonicalPeer =
      frame.dir === "tx" ? nodePeerIds[nodeIdx] || `node-${nodeIdx}` : frame.peer || "";
    wasmHost.ingestWireFrame(frame.hex, canonicalPeer, frame.dir === "tx");
  }

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
      if (!Number.isFinite(latestBlock)) {
        return;
      }

      const startBlock =
        lastScannedBlock === null ? Math.max(0, latestBlock - 32) : lastScannedBlock + 1;
      for (let b = startBlock; b <= latestBlock; b++) {
        const blkResp = await rpcJsonCall(opts.rpcUrl, {
          jsonrpc: "2.0",
          id: 100 + b,
          method: "eth_getBlockByNumber",
          params: [`0x${b.toString(16)}`, true],
        });
        const txs = blkResp?.result?.transactions || [];
        for (const tx of txs) {
          if (!tx || !tx.to || tx.to.toLowerCase() !== contractLower) {
            continue;
          }
          const input = (tx.input || "").toLowerCase();
          if (!input.startsWith(SUBMIT_MEDIANS_SELECTOR) || input.length < 74) {
            continue;
          }
          if (seenReceipts.has(tx.hash)) {
            continue;
          }
          const rcptResp = await rpcJsonCall(opts.rpcUrl, {
            jsonrpc: "2.0",
            id: 2000 + b,
            method: "eth_getTransactionReceipt",
            params: [tx.hash],
          });
          const rcpt = rcptResp?.result;
          if (!rcpt || rcpt.status !== "0x1") {
            continue;
          }
          seenReceipts.add(tx.hash);
          const roundId = Number(BigInt("0x" + input.slice(10, 74)));
          const gasUsed = Number(BigInt(rcpt.gasUsed || "0x0"));
          const nextCount = (roundTxCounts.get(roundId) || 0) + 1;
          roundTxCounts.set(roundId, nextCount);
          wasmHost.ingestTx(roundId, b, gasUsed, nextCount, tx.from || "");
        }
        lastScannedBlock = b;
      }
    } catch {
      // Transient RPC disconnect; next interval will retry cleanly
    }
  }

  async function pollNodeStatuses() {
    await Promise.all(
      opts.nodeUrls.map(async (baseUrl, idx) => {
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
              if (nodePeerIds[idx] && nodePeerIds[idx] !== parsed.peer_id) {
                seenSeqs[idx].clear();
              }
              nodePeerIds[idx] = parsed.peer_id;
            }
            if (Array.isArray(parsed?.recent_frames)) {
              for (const frame of parsed.recent_frames) {
                recordFrameOnce(idx, frame);
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
            wasmHost.markNodeOffline(nodeIdx);
            await new Promise((r) => setTimeout(r, 500));
            continue;
          }
          const reader = resp.body.getReader();
          const decoder = new TextDecoder("utf-8");
          let buf = "";
          while (!stopping) {
            const { value, done } = await reader.read();
            if (done) {
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
                if (ev.event === "status") {
                  if (ev.peer_id) {
                    if (nodePeerIds[nodeIdx] && nodePeerIds[nodeIdx] !== ev.peer_id) {
                      seenSeqs[nodeIdx].clear();
                    }
                    nodePeerIds[nodeIdx] = ev.peer_id;
                  }
                  if (Array.isArray(ev.recent_frames)) {
                    for (const frame of ev.recent_frames) {
                      recordFrameOnce(nodeIdx, frame);
                    }
                  }
                  wasmHost.ingestNodeStatus(nodeIdx, payload);
                } else if (ev.event === "frame") {
                  recordFrameOnce(nodeIdx, ev);
                }
              } catch {
                // Ignore non-JSON comments/partial lines
              }
            }
          }
        } catch {
          if (!stopping) {
            wasmHost.markNodeOffline(nodeIdx);
          }
        }
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

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
