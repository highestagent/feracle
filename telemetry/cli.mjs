import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..");

const DEFAULT_RPC_URL = "http://127.0.0.1:8545";
const DEFAULT_ORACLES = [
  "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
  "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
  "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
].join(",");
const DEFAULT_WASM_PATH = path.join(REPO_ROOT, "out", "telemetry_wasm.wasm");

function printHelp() {
  console.log(`Feracle WASM Telemetry Host (Node.js)

Usage: node telemetry/host.mjs [OPTIONS]

Options:
  --rpc-url <URL>        EVM JSON-RPC endpoint URL [env: FERACLE_RPC_URL] [default: ${DEFAULT_RPC_URL}]
  --contract <ADDR>      Deployed OffchainMedianOracle address (required) [env: FERACLE_CONTRACT]
  --oracles <CSV>        Comma-separated oracle addresses (up to 4) [env: FERACLE_ORACLES]
  --nodes <CSV>          Optional comma-separated node telemetry URLs (e.g. http://127.0.0.1:9101,...) [env: FERACLE_NODES]
  --wasm <PATH>          Path to compiled Fe WASM module [env: FERACLE_WASM] [default: ${DEFAULT_WASM_PATH}]
  --interval-ms <MS>     Poll & refresh interval in milliseconds [default: 1000]
  --mode <MODE>          Output mode: tui | json | prometheus [default: tui]
  --once                 Run one collection cycle, print output once, and exit
  --no-ansi              Disable ANSI clear-screen and color escapes in TUI mode
  --metrics-port <PORT>  Optional HTTP port serving /metrics (Prometheus) and /status (JSON)
  -h, --help             Print help
`);
}

export function parseCliArgs(argv) {
  const opts = {
    rpcUrl: process.env.FERACLE_RPC_URL || DEFAULT_RPC_URL,
    contract: process.env.FERACLE_CONTRACT || "",
    oracles: process.env.FERACLE_ORACLES || DEFAULT_ORACLES,
    nodes: process.env.FERACLE_NODES || "",
    wasm: process.env.FERACLE_WASM || DEFAULT_WASM_PATH,
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
    console.error("Missing required --contract <ADDR> (or FERACLE_CONTRACT)");
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
