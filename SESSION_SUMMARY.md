# Crank Session Summary — 2026-04-02

## Project Overview

**Crank** is a personal Elixir library for finite state machines — pure, testable data structures first, with an optional gen_statem process adapter.

- **Repo**: github.com/code-of-kai/crank (GitHub account: code-of-kai)
- **Hex package name**: `crank`
- **Version**: 0.1.0
- **Local path**: `/Users/kaitaylor/Documents/Coding/Crank`

## What Was Done This Session

### 1. Directory Rename
Renamed local project directory from `Decidable` to `Crank` (`/Users/kaitaylor/Documents/Coding/Decidable` → `/Users/kaitaylor/Documents/Coding/Crank`).

### 2. Verified Git/GitHub Already Correct
- Git remote already pointed to `code-of-kai/crank.git`
- GitHub repo already named `crank`
- Only the local directory name was lagging behind

### 3. GitHub Account
Switched session to personal GitHub account `code-of-kai` via `GH_TOKEN` env var.

### 4. Working Directory Discussion
Claude Code's primary working directory is set at launch and cannot be changed mid-session via config file. User should start next session from `~/Documents/Coding/Crank`.

## Prior Session Work (Carried Forward)

The project was built from scratch in a prior conversation. Key deliverables:

### Architecture
- **Pure core / effectful shell**: `handle_event/4` is pure, `Crank.Server` is the process adapter
- **Arity-4 callback**: `handle_event(event_type, event_content, state, data)` — same argument order as gen_statem
- **Effects as data**: Stored in `machine.effects`, replaced per crank, never executed by pure core
- **Telemetry outbound port**: `[:crank, :transition]` with `%{module, from, to, event, data}` metadata
- **Hexagonal architecture**: Via telemetry handlers (persistence, notifications, audit, PubSub)

### Key Files
| File | Description |
|------|-------------|
| `lib/crank.ex` | Main module, behaviour, pure API (`new/2`, `crank/2`, `crank!/2`) |
| `lib/crank/machine.ex` | `%Crank.Machine{}` struct with parameterized types |
| `lib/crank/server.ex` | `Crank.Server` client API + `Crank.Server.Adapter` (gen_statem) |
| `lib/crank/stopped_error.ex` | `Crank.StoppedError` exception |
| `lib/crank/examples.ex` | Door, Turnstile, Order example machines |
| `test/crank_test.exs` | 24 example tests + 6 doctests |
| `test/crank_server_test.exs` | Server lifecycle, cast/call, telemetry tests |
| `test/crank/property/crank_property_test.exs` | 19 properties, 10K runs each, ~100M random cranks |
| `test/support/crank_generators.ex` | StreamData generators |
| `guides/hexagonal-architecture.md` | Hexagonal architecture guide |
| `DESIGN.md` | Design spec with 12 key decisions |
| `CHANGELOG.md` | Keep a Changelog format |
| `README.md` | Quick start and API docs |

### Test Suite
- **49 tests** (6 doctests + 19 properties + 24 examples), 0 failures
- **~100M random cranks** across property tests in ~18 seconds
- 19 invariants including: struct integrity, effects isolation, conservation, determinism, state reachability, terminal stop, monotonicity, on_enter correctness, pure/process equivalence, multi-sender conservation, restart equivalence, and 6 Order machine properties

### Design Process
Names and architecture were refined through channeling José Valim, Joe Armstrong, and Richard Feynman:
- `Decidable` → `Crank` (Feynman's suggestion)
- `transition` → `crank` (user's suggestion)
- `pending_actions` → `effects`
- `Impl` → `Adapter`
- Kept `Server` for ecosystem familiarity

### Dependencies
```elixir
{:telemetry, "~> 1.0"},
{:stream_data, "~> 1.1", only: :test},
{:ex_doc, "~> 0.34", only: :dev, runtime: false}
```

## What's Next
- Ready for `mix hex.publish` (requires Hex auth credentials)
- Pre-1.0 remaining item: real users providing feedback on the API surface
- Next session should be started from `~/Documents/Coding/Crank` for correct working directory
