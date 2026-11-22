# `cli` — CLI Parser & Runner

An effect-polymorphic command-line parsing library for native Fe programs.

## Quick Start

Add the dependency to `fe.toml`:

```toml
[dependencies]
cli = { path = "../cli" }
```

Define an `App`, inject parsed `Matches` as a `Cli` capability via `with (Cli = matches)`, and read typed values using return-type inference:

```fe
use std::env::{Args, Env}
use std::io::{Stderr, Stdout}
use cli::{App, Arg, Cli, CliError, Matches}

struct Config {
    port: u16,
    verbose: bool,
}

fn load_config() -> Result<CliError, Config> uses (cli: Cli) {
    let port: u16 = cli::require("port")?
    let verbose = cli.cli_flag("verbose".span())
    Result::Ok(Config { port, verbose })
}

pub fn main() -> i32 uses (args: Args, env: Env, out: mut Stdout, err: mut Stderr) {
    App::new("mytool")
        .version("0.1.0")
        .about("Example CLI tool")
        .arg(Arg::option("port").short(b'p').env("MYTOOL_PORT").default_value("8080"))
        .arg(Arg::flag("verbose").short(b'v').help("Enable verbose output"))
        .run(|matches: Matches| -> i32 {
            let cfg = match (with (Cli = matches) { load_config() }) {
                Result::Ok(c) => c,
                Result::Err(e) => {
                    eprintln!(e)
                    return e.exit_code()
                }
            }
            println!("port=", cfg.port, " verbose=", cfg.verbose)
            0
        })
}
```

---

## Architecture

```text
Input (uses E) ──▶ parser::parse_app ──▶ Result<CliError, Matches>
  │                                            │
  ├─ HostInput   (Args, Env)                   ├─ Ok(matches) ─▶ App::run / with (Cli = matches)
  └─ MemoryInput (pure, tests)                 └─ Err(err)    ─▶ Output (HostOutput / BufferOutput)
```

| Module | Responsibility |
| --- | --- |
| `src/lib.fe` | Public re-exports (`App`, `Arg`, `Matches`, `Cli`, `CliError`, `FromArg`, `Input`, `Output`, `MemoryInput`, `BufferOutput`, `ValueSource`) |
| `src/spec.fe` | Fluent `var own self` builders for `App` and `Arg` (`Flag`, `Option`, `Multi`, `Positional`), plus `.parse()`, `.parse_with()`, `.run()`, `.run_io()` |
| `src/io.fe` | `Input` / `Output` capability traits (`uses E`), host adapters (`HostInput`, `HostOutput`), and pure test adapters (`MemoryInput`, `BufferOutput`) |
| `src/parser.fe` | Tokenizer, GNU/POSIX flag/value parsing, subcommand recursion, `CLI > Env > Default` resolution, and cross-arg validation |
| `src/matches.fe` | `Matches` (`HashMap`-backed values, `Box<Matches>` subcommand tree), `Cli` capability trait, and `cli::get` / `require` / `get_or` / `get_many` helpers |
| `src/value.fe` | `FromArg` trait with built-in impls for ints (`u8..u256`, `i8..i256`, `usize`, `isize`), `bool`, `MemBuffer`, `IpAddr`, `Ipv4Addr`, `Ipv6Addr`, `SocketAddr` |
| `src/help.fe` | Auto-aligned `--help` and `--version` formatter |
| `src/error.fe` | `#[must_use]` `CliError`, `Display` diagnostics, exit codes (`0` / `2`), and `levenshtein` / `closest_match` typo suggestions |

---

## Common Patterns

### Custom `FromArg` Type

```fe
use std::net::SocketAddr
use cli::FromArg

struct Endpoint { addr: SocketAddr }

impl FromArg for Endpoint {
    fn from_arg(_ raw: MemSpan) -> Result<MemBuffer, Self> {
        let Option::Some(addr) = SocketAddr::parse(raw) else {
            return Result::Err(format!("expected IP:PORT"))
        }
        Result::Ok(Endpoint { addr })
    }
}
```

### Subcommands

```fe
let app = App::new("ctl")
    .subcommand_required()
    .subcommand(App::new("serve").about("Start server").arg(Arg::option("port").default_value("8080")))

let matches = app.parse()?
let port = matches.with_subcommand(|_ name: MemBuffer, sub: Matches| -> u16 {
    sub.require<u16>("port").unwrap()
})
```

### Pure Unit Testing (No Process/Stdio Needed)

```fe
use cli::{App, Arg, BufferOutput, Matches, MemoryInput}

#[test]
fn test_cli() {
    let app = App::new("t").arg(Arg::option("port").short(b'p'))
    let input = MemoryInput::new("t").arg("-p7001")
    var out = BufferOutput::new()

    let code = app.run_io(input, mut out, |m: Matches| -> i32 {
        assert!(m.require<u16>("port").unwrap() == 7001)
        0
    })
    assert!(code == 0)
}
```

Run the built-in suite:

```bash
fe test --backend native ingots/cli
```

---

## Supported Syntax & Features

- **Flags & options:** `--opt val`, `--opt=val`, `-o val`, `-o=val`, `-oVAL`, bundled short flags (`-vvf`, tracked by `count()`), `--` end-of-options terminator.
- **Arg kinds & modifiers:** `Arg::flag`, `Arg::option`, `Arg::multi` (repeatable + `.delimiter(b',')`), `Arg::positional` (`.multiple()`), `.short`, `.long`, `.no_long`, `.value_name`, `.help`, `.env`, `.default_value`, `.required`, `.allow_override`, `.sensitive` (redacts invalid values to `<redacted>`).
- **Precedence:** `CommandLine > Env > Default` (inspectable via `matches.value_source("id")`).
- **Validation & ergonomics:** `.possible_value`, `.conflicts_with`, `.requires`, `.subcommand_required`, `.arg_required_else_help`, auto `-h`/`--help`, `-V`/`--version`, `help <subcommand>`, and Levenshtein typo suggestions on unknown flags/subcommands.
