import fs from "node:fs";

export class WasmTelemetryHost {
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

export async function rpcJsonCall(rpcUrl, bodyObj) {
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
