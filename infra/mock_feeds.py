#!/usr/bin/env python3
"""Deterministic local mock price feeds for Top-20 crypto/USD pairs (Hyperliquid, Binance, Coinbase)."""

import argparse
import json
import signal
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


ASSETS = [
    ("BTC", "92450.50", "92455.00", "92448.00"),
    ("ETH", "3420.50", "3422.10", "3419.80"),
    ("SOL", "218.40", "218.65", "218.20"),
    ("XRP", "2.4520", "2.4550", "2.4500"),
    ("BNB", "685.20", "685.60", "684.90"),
    ("DOGE", "0.3840", "0.3845", "0.3836"),
    ("ADA", "1.0450", "1.0470", "1.0435"),
    ("TRX", "0.2610", "0.2614", "0.2607"),
    ("AVAX", "44.80", "44.88", "44.74"),
    ("LINK", "23.60", "23.65", "23.56"),
    ("SUI", "4.1520", "4.1580", "4.1480"),
    ("DOT", "8.920", "8.935", "8.910"),
    ("HBAR", "0.2950", "0.2955", "0.2946"),
    ("BCH", "512.30", "512.80", "511.90"),
    ("LTC", "114.60", "114.80", "114.45"),
    ("UNI", "14.750", "14.770", "14.735"),
    ("NEAR", "6.480", "6.492", "6.472"),
    ("APT", "12.350", "12.375", "12.330"),
    ("ARB", "0.9450", "0.9465", "0.9440"),
    ("AAVE", "318.50", "318.90", "318.20"),
]


class ReusableThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True


def build_price_map(
    kind: str,
    btc_override: str,
    outlier_asset: str | None,
    outlier_price: str | None,
) -> dict[str, str]:
    idx = {"hyperliquid": 1, "binance": 2, "coinbase": 3}[kind]
    prices = {row[0]: row[idx] for row in ASSETS}
    prices["BTC"] = btc_override
    if outlier_asset and outlier_price is not None:
        key = outlier_asset.upper()
        if key in prices:
            prices[key] = outlier_price
    return prices


def make_handler(kind: str, prices: dict[str, str]):
    class FeedHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format, *args):
            return

        def _send_json(self, status: int, payload):
            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            path = urlparse(self.path).path
            content_len = int(self.headers.get("Content-Length", "0"))
            if content_len > 0:
                self.rfile.read(content_len)
            if kind == "hyperliquid" and path == "/info":
                self._send_json(200, prices)
            else:
                self._send_json(404, {"error": "not found"})

        def do_GET(self):
            parsed = urlparse(self.path)
            path = parsed.path
            qs = parse_qs(parsed.query)
            if kind == "binance" and path == "/api/v3/ticker/price":
                if "symbol" in qs and qs["symbol"]:
                    sym_req = qs["symbol"][0]
                    base = sym_req[:-4] if sym_req.endswith("USDT") else sym_req
                    if base in prices:
                        self._send_json(200, {"symbol": sym_req, "price": prices[base]})
                    else:
                        self._send_json(404, {"error": "unknown symbol"})
                    return
                if "symbols" in qs and qs["symbols"]:
                    try:
                        req_list = json.loads(qs["symbols"][0])
                    except Exception:
                        self._send_json(400, {"error": "bad symbols query"})
                        return
                    out = []
                    for sym_req in req_list:
                        base = sym_req[:-4] if sym_req.endswith("USDT") else sym_req
                        if base in prices:
                            out.append({"symbol": sym_req, "price": prices[base]})
                    self._send_json(200, out)
                    return
                self._send_json(
                    200,
                    [{"symbol": f"{row[0]}USDT", "price": prices[row[0]]} for row in ASSETS],
                )
            elif kind == "coinbase" and path.startswith("/products/") and path.endswith("/ticker"):
                pair = path[len("/products/"):-len("/ticker")]
                if pair.endswith("-USD"):
                    base = pair[:-4]
                    if base in prices:
                        self._send_json(200, {"price": prices[base]})
                        return
                self._send_json(404, {"error": "unknown pair"})
            else:
                self._send_json(404, {"error": "not found"})

    return FeedHandler


def main():
    parser = argparse.ArgumentParser(description="Mock Top-20 crypto/USD price feed servers")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port-hl", type=int, default=9001)
    parser.add_argument("--port-binance", type=int, default=9002)
    parser.add_argument("--port-coinbase", type=int, default=9003)
    parser.add_argument("--price-hl", default="92450.50")
    parser.add_argument("--price-binance", default="92455.00")
    parser.add_argument("--price-coinbase", default="92448.00")
    parser.add_argument("--outlier-port", type=int, default=None)
    parser.add_argument("--outlier-asset", default="BTC")
    parser.add_argument("--outlier-price", default=None)
    args = parser.parse_args()

    configs = [
        ("hyperliquid", args.port_hl, args.price_hl),
        ("binance", args.port_binance, args.price_binance),
        ("coinbase", args.port_coinbase, args.price_coinbase),
    ]

    servers = []
    threads = []
    for kind, port, btc_price in configs:
        is_outlier = (
            args.outlier_port is not None
            and args.outlier_price is not None
            and port == args.outlier_port
        )
        price_map = build_price_map(
            kind,
            btc_override=btc_price,
            outlier_asset=args.outlier_asset if is_outlier else None,
            outlier_price=args.outlier_price if is_outlier else None,
        )
        srv = ReusableThreadingHTTPServer((args.host, port), make_handler(kind, price_map))
        servers.append(srv)
        t = threading.Thread(target=srv.serve_forever, daemon=True)
        t.start()
        threads.append(t)

    stop_event = threading.Event()

    def handle_sig(signum, frame):
        stop_event.set()

    signal.signal(signal.SIGINT, handle_sig)
    signal.signal(signal.SIGTERM, handle_sig)

    sys.stdout.write(
        f"mock_feeds ready on {args.host}: {args.port_hl} (hl), "
        f"{args.port_binance} (binance), {args.port_coinbase} (coinbase) [20 assets]\n"
    )
    sys.stdout.flush()

    while not stop_event.is_set():
        stop_event.wait(0.25)

    for srv in servers:
        srv.shutdown()
        srv.server_close()


if __name__ == "__main__":
    main()
