export const MEDIANS_SUBMITTED_TOPIC =
  "0xf2da0e6afc773e2239fc39b0cab487f90ff53838719584aab05eeed38611e097";
export const INITIAL_LOG_LOOKBACK = 256;
export const MAX_LOG_BLOCK_SPAN = 1000;
export const MAX_SEEN_RECEIPTS = 512;
export const MAX_ROUND_TX_COUNTS = 256;
export const MAX_FRAME_SEQS = 512;

export function addBoundedSet(set, key, maxSize) {
  if (set.has(key)) {
    return false;
  }
  while (set.size >= maxSize) {
    const oldest = set.values().next().value;
    if (oldest === undefined) break;
    set.delete(oldest);
  }
  set.add(key);
  return true;
}

export function setBoundedMap(map, key, value, maxSize) {
  if (map.has(key)) {
    map.delete(key);
  } else {
    while (map.size >= maxSize) {
      const oldest = map.keys().next().value;
      if (oldest === undefined) break;
      map.delete(oldest);
    }
  }
  map.set(key, value);
}

export function shouldSkipStatusPoll(connected, lastEventAt, now = Date.now(), staleMs = 15000) {
  return Boolean(connected && lastEventAt > 0 && now - lastEventAt < staleMs);
}

export function createFrameDeduper({
  nodeCount,
  maxSeqs = MAX_FRAME_SEQS,
  ingestWireFrame,
}) {
  const nodePeerIds = new Array(nodeCount).fill(null);
  const seenSeqs = Array.from({ length: nodeCount }, () => new Set());

  function updatePeerId(nodeIdx, peerId) {
    if (!peerId) return;
    if (nodePeerIds[nodeIdx] && nodePeerIds[nodeIdx] !== peerId) {
      seenSeqs[nodeIdx].clear();
    }
    nodePeerIds[nodeIdx] = peerId;
  }

  function recordFrameOnce(nodeIdx, frame) {
    if (!frame || !frame.hex || typeof frame.seq !== "number") {
      return false;
    }
    const set = seenSeqs[nodeIdx];
    if (!addBoundedSet(set, frame.seq, maxSeqs)) {
      return false;
    }
    const canonicalPeer =
      frame.dir === "tx" ? nodePeerIds[nodeIdx] || `node-${nodeIdx}` : frame.peer || "";
    ingestWireFrame(frame.hex, canonicalPeer, frame.dir === "tx");
    return true;
  }

  return {
    updatePeerId,
    recordFrameOnce,
    getPeerId(nodeIdx) {
      return nodePeerIds[nodeIdx];
    },
    seenCount(nodeIdx) {
      return seenSeqs[nodeIdx].size;
    },
  };
}

export function createSettlementIndexer({
  rpcCall,
  contract,
  ingestTx,
  maxReceipts = MAX_SEEN_RECEIPTS,
  maxRounds = MAX_ROUND_TX_COUNTS,
  initialLookback = INITIAL_LOG_LOOKBACK,
  maxBlockSpan = MAX_LOG_BLOCK_SPAN,
}) {
  const seenReceipts = new Set();
  const roundTxCounts = new Map();
  let lastScannedBlock = null;

  function reset() {
    lastScannedBlock = null;
    seenReceipts.clear();
    roundTxCounts.clear();
  }

  async function processLatestBlock(latestBlock) {
    if (!Number.isFinite(latestBlock)) {
      return;
    }
    if (lastScannedBlock !== null && latestBlock < lastScannedBlock) {
      reset();
    }
    if (lastScannedBlock !== null && latestBlock <= lastScannedBlock) {
      return;
    }

    const startBlock =
      lastScannedBlock === null
        ? Math.max(0, latestBlock - initialLookback)
        : lastScannedBlock + 1;
    for (let fromBlock = startBlock; fromBlock <= latestBlock; fromBlock += maxBlockSpan) {
      const toBlock = Math.min(latestBlock, fromBlock + maxBlockSpan - 1);
      const logsResp = await rpcCall({
        jsonrpc: "2.0",
        id: 100 + fromBlock,
        method: "eth_getLogs",
        params: [
          {
            address: contract,
            fromBlock: `0x${fromBlock.toString(16)}`,
            toBlock: `0x${toBlock.toString(16)}`,
            topics: [MEDIANS_SUBMITTED_TOPIC],
          },
        ],
      });
      if (logsResp?.error || !Array.isArray(logsResp?.result)) {
        return;
      }
      for (const log of logsResp.result) {
        if (!log || log.removed || !log.transactionHash || seenReceipts.has(log.transactionHash)) {
          continue;
        }
        if (!Array.isArray(log.topics) || log.topics.length < 2) {
          continue;
        }
        const roundId = Number(BigInt(log.topics[1]));
        const blockNum = Number(BigInt(log.blockNumber || "0x0"));
        const rcptResp = await rpcCall({
          jsonrpc: "2.0",
          id: 2000 + blockNum,
          method: "eth_getTransactionReceipt",
          params: [log.transactionHash],
        });
        const rcpt = rcptResp?.result;
        if (!rcpt) {
          return;
        }
        if (rcpt.status !== "0x1") {
          continue;
        }
        addBoundedSet(seenReceipts, log.transactionHash, maxReceipts);
        const gasUsed = Number(BigInt(rcpt.gasUsed || "0x0"));
        const nextCount = (roundTxCounts.get(roundId) || 0) + 1;
        setBoundedMap(roundTxCounts, roundId, nextCount, maxRounds);
        ingestTx(roundId, blockNum, gasUsed, nextCount, rcpt.from || "");
      }
      lastScannedBlock = toBlock;
    }
  }

  return {
    reset,
    processLatestBlock,
    getState() {
      return {
        lastScannedBlock,
        seenReceiptsSize: seenReceipts.size,
        roundTxCounts: new Map(roundTxCounts),
      };
    },
  };
}
