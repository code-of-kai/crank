# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-04-08

### Added

- `Crank.snapshot/1` — captures a machine's module, state, and data as a plain map, ready to serialize and persist.
- `Crank.from_snapshot/1` — rebuilds a machine from a snapshot map without calling `init/1`.
- `Crank.resume/3` — same as `from_snapshot/1` with positional arguments (`module`, `state`, `data`).
- `Crank.Server.start_from_snapshot/2` and `start_from_snapshot/4` — start a supervised `gen_statem` process from a snapshot without calling `module.init/1`.
- `[:crank, :resume]` telemetry event — emitted whenever a machine is restored via `from_snapshot/1`, `resume/3`, or `start_from_snapshot/2`.
- `on_enter/3` suppression on resume — resumed machines do not fire the state-enter callback, because they are resuming, not entering a state for the first time.
- Persistence section in the README covering all three storage strategies: snapshot-per-transition, event sourcing, and hybrid.
- Documentation-wide Feynman-style clarity pass: every `@moduledoc`, `@doc`, and `@typedoc` rewritten for concrete-before-abstract explanations, inline jargon definitions, and shorter single-job paragraphs.

### Changed

- `Crank.Server.Adapter` now carries a `suppress_next_enter` flag to support the resume path.
- Hexagonal architecture guide restructured: opens with a working persistence adapter in 20 lines, then explains the pattern.
- README restructured: show working code first, explain after, convince third, reference last.

## [0.2.0] - 2026-04-07

### Added

- `handle/3` callback — simplified signature that drops `event_type`. Primary callback for business logic that works in both pure and process contexts.
- `handle_event/4` takes precedence when both callbacks are defined, enabling mixed usage with a one-line catch-all delegation.
- Runtime dispatch in `Crank.crank/2` and `Crank.Server.Adapter` — prefers `handle_event/4` if exported, falls back to `handle/3`.
- Validation accepts `handle/3` or `handle_event/4` (at least one required).
- Error messages reference the correct callback name (`handle/3` vs `handle_event/4`).

### Changed

- `handle_event/4` is now an optional callback (was required). Modules can implement `handle/3` instead.
- `@optional_callbacks` updated to `[handle: 3, handle_event: 4, on_enter: 3]`.
- README rewritten with vending machine example throughout (5 states: Idle, Accepting, Dispensing, MakingChange, OutOfStock).
- README restructured around domain-driven design vocabulary: domain model, domain events, anemic model, making illegal states unrepresentable, hexagonal architecture.
- "Why not just use GenServer?" section leads with the simplicity argument: Crank's pure mode is simpler than GenServer.
- Hexagonal architecture guide rewritten with why-first approach and vending machine examples.
- DESIGN.md updated for `handle/3` callback and vending machine struct-per-state examples.
- Package description updated with "finite state machine (FSM)" search terms.

## [0.1.0] - 2026-04-01

### Added

- `Crank` behaviour with `init/1`, `handle_event/4`, and optional `on_enter/3` callbacks
- `Crank.Machine` struct — pure state machine as data, with parameterized `t(state, data)` type
- `Crank.crank/2` and `Crank.crank!/2` — pure transition functions, pipeline-friendly
- `Crank.new/2` — constructor with module validation
- `Crank.Server` — thin `:gen_statem` adapter with zero extra callbacks
- `Crank.Server.Adapter` — internal gen_statem implementation
- `Crank.StoppedError` — raised when cranking a stopped machine
- Effects as data — actions stored in `machine.effects`, never executed in pure core
- Telemetry — `[:crank, :transition]` events emitted by Server on every state change
- Arity-4 `handle_event(event_type, event_content, state, data)` — same argument order as gen_statem's `handle_event_function` mode
- Event type passthrough — Server passes gen_statem event types directly to callbacks
- `:internal` event type for pure transitions
- Module validation at init (both `Crank.new/2` and `Crank.Server.Adapter.init/1`)
- Invalid callback return detection with clear error messages
- `Crank.Examples.Door` — minimal example (4 states, 4 events)
- `Crank.Examples.Turnstile` — total example (2 states, 2 events, all combinations handled)
- `Crank.Examples.Order` — complex example (5 states, 8 events, effects, on_enter)
- 19 property-based tests across ~80M random cranks
- 6 doctests on all public API functions
- Full `@type`, `@spec`, and `@typedoc` coverage for Elixir's type future
