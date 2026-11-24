import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  INITIAL_LOG_LOOKBACK,
  MAX_LOG_BLOCK_SPAN,
  MEDIANS_SUBMITTED_TOPIC,
  addBoundedSet,
  createFrameDeduper,
  createSettlementIndexer,
  isDirectEntrypoint,
  parseCliArgs,
  setBoundedMap,
  shouldSkipStatusPoll,
} from "./host.mjs";

test("addBoundedSet and setBoundedMap enforce LRU caps", () => {
  const seen = new Set();
  assert.equal(addBoundedSet(seen, "a", 3), true);
  assert.equal(addBoundedSet(seen, "b", 3), true);
  assert.equal(addBoundedSet(seen, "b", 3), false);
  assert.equal(addBoundedSet(seen, "c", 3), true);
  assert.equal(addBoundedSet(seen, "d", 3), true);
  assert.deepEqual([...seen], ["b", "c", "d"]);

  const counts = new Map();
  setBoundedMap(counts, 1, 10, 2);
  setBoundedMap(counts, 2, 20, 2);
  // Updating key 1 refreshes its recency so key 2 is evicted next.
  setBoundedMap(counts, 1, 11, 2);
  setBoundedMap(counts, 3, 30, 2);
  assert.deepEqual([...counts.entries()], [
    [1, 11],
    [3, 30],
  ]);
});

test("createFrameDeduper deduplicates frames, caps seqs, and resets on peer change", () => {
  const ingested = [];
  const deduper = createFrameDeduper({
    nodeCount: 2,
    maxSeqs: 3,
    ingestWireFrame: (hex, peer, isTx) => ingested.push({ hex, peer, isTx }),
  });

  assert.equal(deduper.recordFrameOnce(0, null), false);
  assert.equal(deduper.recordFrameOnce(0, { hex: "0x01" }), false);

  deduper.updatePeerId(0, "12D3KooWNode0");
  assert.equal(deduper.recordFrameOnce(0, { seq: 1, hex: "01", dir: "tx" }), true);
  assert.equal(deduper.recordFrameOnce(0, { seq: 1, hex: "01", dir: "tx" }), false);
  assert.equal(
    deduper.recordFrameOnce(1, { seq: 2, hex: "02", dir: "rx", peer: "peer-remote" }),
    true
  );

  // Fill beyond maxSeqs=3 on node 0; oldest seq=1 is evicted and can be ingested again if re-sent later.
  assert.equal(deduper.recordFrameOnce(0, { seq: 2, hex: "02", dir: "tx" }), true);
  assert.equal(deduper.recordFrameOnce(0, { seq: 3, hex: "03", dir: "tx" }), true);
  assert.equal(deduper.recordFrameOnce(0, { seq: 4, hex: "04", dir: "tx" }), true);
  assert.equal(deduper.seenCount(0), 3);

  // Node restart changes peer_id -> clears seen seqs for that node.
  deduper.updatePeerId(0, "12D3KooWNode0Restarted");
  assert.equal(deduper.seenCount(0), 0);
  assert.equal(deduper.recordFrameOnce(0, { seq: 1, hex: "11", dir: "tx" }), true);

  assert.deepEqual(ingested[0], { hex: "01", peer: "12D3KooWNode0", isTx: true });
  assert.deepEqual(ingested[1], { hex: "02", peer: "peer-remote", isTx: false });
  assert.deepEqual(ingested.at(-1), {
    hex: "11",
    peer: "12D3KooWNode0Restarted",
    isTx: true,
  });
});

test("shouldSkipStatusPoll respects SSE freshness threshold", () => {
  const now = 100_000;
  assert.equal(shouldSkipStatusPoll(true, now - 5_000, now), true);
  assert.equal(shouldSkipStatusPoll(true, now - 14_999, now), true);
  assert.equal(shouldSkipStatusPoll(true, now - 15_000, now), false);
  assert.equal(shouldSkipStatusPoll(false, now - 1_000, now), false);
  assert.equal(shouldSkipStatusPoll(true, 0, now), false);
});

test("createSettlementIndexer queries eth_getLogs chunks, receipts, retries, and reorgs", async () => {
  const rpcRequests = [];
  const ingestedTxs = [];
  const logsByRange = new Map();
  const receiptsByHash = new Map();

  const indexer = createSettlementIndexer({
    contract: "0x1111111111111111111111111111111111111111",
    maxReceipts: 2,
    maxRounds: 2,
    ingestTx: (roundId, blockNum, gasUsed, count, from) =>
      ingestedTxs.push({ roundId, blockNum, gasUsed, count, from }),
    rpcCall: async (req) => {
      rpcRequests.push(req);
      if (req.method === "eth_getLogs") {
        const [{ fromBlock, toBlock, topics }] = req.params;
        assert.equal(topics[0], MEDIANS_SUBMITTED_TOPIC);
        return {
          jsonrpc: "2.0",
          id: req.id,
          result: logsByRange.get(`${fromBlock}-${toBlock}`) || [],
        };
      }
      if (req.method === "eth_getTransactionReceipt") {
        return {
          jsonrpc: "2.0",
          id: req.id,
          result: receiptsByHash.get(req.params[0]) ?? null,
        };
      }
      throw new Error(`unexpected RPC method: ${req.method}`);
    },
  });

  // Initial scan on block 300 looks back INITIAL_LOG_LOOKBACK blocks (44..300)
  logsByRange.set("0x2c-0x12c", [
    {
      transactionHash: "0xtx1",
      blockNumber: "0x12b",
      topics: [MEDIANS_SUBMITTED_TOPIC, "0x01"],
      removed: false,
    },
    {
      transactionHash: "0xtx_removed",
      blockNumber: "0x12b",
      topics: [MEDIANS_SUBMITTED_TOPIC, "0x01"],
      removed: true,
    },
    {
      transactionHash: "0xtx_reverted",
      blockNumber: "0x12c",
      topics: [MEDIANS_SUBMITTED_TOPIC, "0x01"],
      removed: false,
    },
  ]);
  receiptsByHash.set("0xtx1", { status: "0x1", gasUsed: "0x5208", from: "0xalice" });
  receiptsByHash.set("0xtx_reverted", { status: "0x0", gasUsed: "0x1000", from: "0xbob" });

  await indexer.processLatestBlock(300);
  assert.equal(rpcRequests[0].method, "eth_getLogs");
  assert.deepEqual(rpcRequests[0].params[0], {
    address: "0x1111111111111111111111111111111111111111",
    fromBlock: `0x${(300 - INITIAL_LOG_LOOKBACK).toString(16)}`,
    toBlock: "0x12c",
    topics: [MEDIANS_SUBMITTED_TOPIC],
  });
  assert.deepEqual(ingestedTxs, [
    { roundId: 1, blockNum: 299, gasUsed: 21000, count: 1, from: "0xalice" },
  ]);
  assert.equal(indexer.getState().lastScannedBlock, 300);

  // Same block is skipped completely
  const callsBeforeSkip = rpcRequests.length;
  await indexer.processLatestBlock(300);
  assert.equal(rpcRequests.length, callsBeforeSkip);

  // Advance > MAX_LOG_BLOCK_SPAN (301..1550 -> two chunks: 301..1300 and 1301..1550)
  // Missing receipt in chunk 2 pauses before advancing lastScannedBlock past chunk 2.
  logsByRange.set(`0x12d-0x${(301 + MAX_LOG_BLOCK_SPAN - 1).toString(16)}`, [
    {
      transactionHash: "0xtx2",
      blockNumber: "0x200",
      topics: [MEDIANS_SUBMITTED_TOPIC, "0x02"],
      removed: false,
    },
  ]);
  receiptsByHash.set("0xtx2", { status: "0x1", gasUsed: "0x6000", from: "0xcarol" });
  logsByRange.set(`0x${(301 + MAX_LOG_BLOCK_SPAN).toString(16)}-0x60e`, [
    {
      transactionHash: "0xtx3_pending_rcpt",
      blockNumber: "0x550",
      topics: [MEDIANS_SUBMITTED_TOPIC, "0x03"],
      removed: false,
    },
  ]);

  await indexer.processLatestBlock(1550);
  assert.equal(indexer.getState().lastScannedBlock, 301 + MAX_LOG_BLOCK_SPAN - 1);
  assert.equal(ingestedTxs.length, 2);

  // Retry once receipt is available -> finishes chunk 2 without re-ingesting tx2
  receiptsByHash.set("0xtx3_pending_rcpt", {
    status: "0x1",
    gasUsed: "0x7000",
    from: "0xdave",
  });
  await indexer.processLatestBlock(1550);
  assert.equal(indexer.getState().lastScannedBlock, 1550);
  assert.equal(indexer.getState().seenReceiptsSize, 2);
  assert.equal(indexer.getState().roundTxCounts.size, 2);
  assert.deepEqual(ingestedTxs.at(-1), {
    roundId: 3,
    blockNum: 1360,
    gasUsed: 28672,
    count: 1,
    from: "0xdave",
  });

  // Chain reorg (latestBlock drops below lastScannedBlock) resets state cleanly
  await indexer.processLatestBlock(10);
  assert.equal(indexer.getState().lastScannedBlock, 10);
  assert.equal(indexer.getState().seenReceiptsSize, 0);
  assert.equal(indexer.getState().roundTxCounts.size, 0);
});

test("parseCliArgs parses endpoints, node list, and telemetry flags", () => {
  const opts = parseCliArgs([
    "--rpc-url",
    "http://127.0.0.1:9545",
    "--contract=0x2222222222222222222222222222222222222222",
    "--nodes",
    "http://127.0.0.1:9101/, ,http://127.0.0.1:9102",
    "--interval-ms=500",
    "--mode",
    "json",
    "--once",
    "--metrics-port=9200",
  ]);
  assert.equal(opts.rpcUrl, "http://127.0.0.1:9545");
  assert.equal(opts.contract, "0x2222222222222222222222222222222222222222");
  assert.deepEqual(opts.nodeUrls, ["http://127.0.0.1:9101", "http://127.0.0.1:9102"]);
  assert.equal(opts.intervalMs, 500);
  assert.equal(opts.mode, "json");
  assert.equal(opts.once, true);
  assert.equal(opts.ansi, false);
  assert.equal(opts.metricsPort, 9200);
});

test("isDirectEntrypoint resolves symlinks and rejects indirect or empty invocations", () => {
  const realHostPath = fs.realpathSync(fileURLToPath(new URL("./host.mjs", import.meta.url)));
  const hostUrl = pathToFileURL(realHostPath).href;
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "feracle-host-test-"));
  try {
    const symlinkPath = path.join(tmpDir, "host-link.mjs");
    fs.symlinkSync(realHostPath, symlinkPath);
    assert.equal(isDirectEntrypoint(symlinkPath, hostUrl), true);
    assert.equal(isDirectEntrypoint(path.join(tmpDir, "other.mjs"), hostUrl), false);
    assert.equal(isDirectEntrypoint("", hostUrl), false);
    assert.equal(isDirectEntrypoint(undefined, hostUrl), false);
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});
