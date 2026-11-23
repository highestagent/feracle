# `http` — Non-Blocking HTTP/1.1 Client & SSE Server

A consumer-agnostic, single-threaded HTTP/1.1 coroutine client and Server-Sent Events (SSE) server built on `coro` and `net_reactor`.

## Quick Start

Add `coro`, `net_reactor`, and `http` to `fe.toml`:

```toml
[dependencies]
coro = { path = "../coro" }
net_reactor = { path = "../net_reactor" }
http = { path = "../http" }
```

### Bounded Client Request

```fe
use std::net::{Net, SocketAddr}
use std::time::Clock
use coro::{LocalScheduler, Scheduler, block_on}
use http::HttpRequest
use net_reactor::{NetDriver, NetPoller, SocketIo}

fn fetch_json(addr: SocketAddr, req_bytes: MemSpan) -> Option<MemBuffer>
uses (net: mut Net, clock: Clock)
{
    var sched = LocalScheduler::new(0)
    var io = NetPoller::new().unwrap()
    var driver = NetDriver::new(max_wait_ms: 50)

    with (Scheduler = sched, SocketIo = io) {
        let task = sched.alloc_task()
        var req = HttpRequest::start_with_timeout(
            owner: task,
            addr,
            request_bytes: req_bytes,
            timeout_ms: 3000,
        )
        block_on(mut req, mut driver)
    }
}
```

### Server & SSE Broadcasting

```fe
use std::net::{Net, SocketAddr}
use coro::{Scheduler, TaskId}
use http::{HttpEvent, HttpServer}
use net_reactor::SocketIo

fn step_server(addr: SocketAddr, owner: TaskId)
uses (net: mut Net, sched: mut Scheduler, io: mut SocketIo)
{
    var srv = HttpServer::bind(addr, owner).unwrap()
    var events = MemVec<HttpEvent>::new()
    srv.poll_io(mut events)

    var i: usize = 0
    while i < events.len() {
        match events[i] {
            HttpEvent::Request(req) => {
                if req.path == "/events".span() {
                    srv.upgrade_sse(req.token, extra_headers: "".span(), initial_data: "".span())
                } else {
                    srv.respond(
                        req.token,
                        status_line: "200 OK".span(),
                        content_type: "text/plain".span(),
                        extra_headers: "".span(),
                        body: "ok".span(),
                    )
                }
            },
            HttpEvent::SseWritableAfterLag(_tok) => {},
        }
        i += 1
    }
    srv.broadcast_sse_data("{\"ok\":true}".span())
    srv.stop()
}
```

---

## Architecture

```text
  HttpRequest (Coroutine) ──▶ SocketIo TCP connect/write/read ──▶ HTTP/1.0|1.1 200 status check
                                                                      ├─ Content-Length body
                                                                      └─ ChunkedDecoder

  HttpServer (listener)  ──▶ accept_all (<= 64 clients) ──▶ HttpEvent::Request / SseWritableAfterLag
                               ├─ respond / respond_empty (Connection: close)
                               └─ upgrade_sse ─▶ keepalives (10s) + bounded outbox (128 KiB)
```

| Module | Responsibility |
| --- | --- |
| `src/lib.fe` | Public re-exports (`HttpRequest`, `HttpEvent`, `HttpRequestEvent`, `HttpServer`, wire helpers) |
| `src/client.fe` | `HttpRequest` (`impl coro::Coroutine`) and `start_with_timeout` returning `Timeout<HttpRequest>` |
| `src/server.fe` | `HttpServer` managing accept, partial header reads, fixed responses, and SSE streams |
| `src/wire.fe` | ASCII case-insensitive header matching, `ChunkedDecoder`, `decode_chunked`, and request-head parsing |
| `src/test.fe` | Native loopback tests covering chunked responses, cancellation, half-close hangup, and SSE routes |

---

## Testing

```bash
fe test --backend native ingots/http
```

---

## Trade-offs & Limitations

- **Plaintext TCP only (no native TLS):** Sockets use unencrypted `std::net::TcpStream`. When talking to external HTTPS exchange APIs, pair nodes with a local TLS-terminating reverse proxy such as Caddy (`infra/Caddyfile`).
- **HTTP/1.x status & framing constraints:** `HttpRequest` only treats `200` status lines as successful (`Content-Length` or `Transfer-Encoding: chunked`), and `HttpServer` closes connections after single responses rather than reusing keepalive request connections.
- **Bounded memory limits:** Client limits: `MAX_HEADER_LINE = 65536`, `MAX_HEADER_BLOCK = 262144`, `MAX_HTTP_BODY = 1_048_576`. Server limits: `MAX_CLIENTS = 64`, `MAX_REQ_BYTES = 4096`, `REQ_TIMEOUT_MS = 2000`, `SSE_KEEPALIVE_MS = 10_000`, `MAX_SSE_OUTBOX = 131_072` (excess SSE frames mark the client lagged and emit `HttpEvent::SseWritableAfterLag` once drained).

---

## Core API Summary

| Symbol | Role |
| --- | --- |
| `HttpRequest` | Non-blocking HTTP/1.1 client coroutine yielding `Option<MemBuffer>` (`::start`, `::start_with_timeout`) |
| `HttpServer` | Non-blocking HTTP/1.1 & SSE server (`::bind`, `::poll_io`, `::respond`, `::respond_empty`, `::upgrade_sse`, `::send_sse_data`, `::broadcast_sse_data`, `::stop`) |
| `HttpEvent` | Server event enum (`Request(HttpRequestEvent)` / `SseWritableAfterLag(Token)`) |
| `HttpRequestEvent` | Parsed request metadata (`token`, `method`, `path`, `query`) |
| `decode_chunked` | Decodes a complete HTTP chunked transfer body into an output buffer |
