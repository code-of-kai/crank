# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
