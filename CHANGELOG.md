# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-04-01

### Added

- `Rig` behaviour with `init/1`, `handle_event/4`, and optional `on_enter/3` callbacks
- `Rig.Machine` struct — pure state machine as data, with parameterized `t(state, data)` type
- `Rig.crank/2` and `Rig.crank!/2` — pure transition functions, pipeline-friendly
- `Rig.new/2` — constructor with module validation
- `Rig.Server` — thin `:gen_statem` adapter with zero extra callbacks
- `Rig.Server.Adapter` — internal gen_statem implementation
- `Rig.StoppedError` — raised when cranking a stopped machine
- Effects as data — actions stored in `machine.effects`, never executed in pure core
- Telemetry — `[:rig, :transition]` events emitted by Server on every state change
- Arity-4 `handle_event(state, event_type, event_content, data)` matching gen_statem exactly
- Event type passthrough — Server passes gen_statem event types directly to callbacks
- `:internal` event type for pure transitions
- Module validation at init (both `Rig.new/2` and `Rig.Server.Adapter.init/1`)
- Invalid callback return detection with clear error messages
- `Rig.Examples.Door` — minimal example (4 states, 4 events)
- `Rig.Examples.Turnstile` — total example (2 states, 2 events, all combinations handled)
- `Rig.Examples.Order` — complex example (5 states, 8 events, effects, on_enter)
- 19 property-based tests across ~80M random cranks
- 6 doctests on all public API functions
- Full `@type`, `@spec`, and `@typedoc` coverage for Elixir's type future
