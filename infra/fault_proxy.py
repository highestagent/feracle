#!/usr/bin/env python3
import json
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

upstream_url, log_path = sys.argv[1], sys.argv[2]

class FaultProxy(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        try:
            req = json.loads(body.decode("utf-8"))
        except Exception:
            req = {}
        method = req.get("method", "") if isinstance(req, dict) else ""
        if method == "eth_sendRawTransaction":
            with open(log_path, "a", encoding="utf-8") as lf:
                lf.write("blocked eth_sendRawTransaction\n")
            err = json.dumps({
                "jsonrpc": "2.0",
                "id": req.get("id", 1),
                "error": {"code": -32000, "message": "simulated primary RPC failure"},
            }).encode()
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(err)))
            self.end_headers()
            self.wfile.write(err)
            return

        fwd = urllib.request.Request(
            upstream_url,
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(fwd, timeout=5) as resp:
            raw = resp.read()
            self.send_response(resp.status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

ThreadingHTTPServer(("127.0.0.1", 8546), FaultProxy).serve_forever()
