# Dialyzer ignore file.
#
# Elixir 1.20-rc.3's dialyzer reports `:call_without_opaque` for every
# `MapSet.member?/2`, `MapSet.intersection/2`, `MapSet.difference/2`, and
# `MapSet.equal?/2` call where the MapSet is constructed from a literal
# list at compile time. The opaque-type check expects the internal `:map`
# field to carry the `:sets.set(_)` opaque tag, but compile-time
# `MapSet.new/1` produces a plain map. This is a known false positive on
# 1.20-rc; remove this file once the release stabilises.
#
# Each entry pins a single warning by `{file, warning_kind, line}`.

[
  {"lib/crank/suppressions.ex", :call_without_opaque},
  {"lib/crank/purity_trace.ex", :call_without_opaque},
  {"lib/crank/errors/catalog.ex", :call_without_opaque},
  {"lib/mix/tasks/compile/crank.ex", :call_without_opaque},
  # The trace worker's body always ends with `exit/1` — that's intentional
  # (the exit reason carries the trace result back to the caller).
  {"lib/crank/purity_trace.ex", :no_return},
  # `handle_worker_timeout/4` ends in `handle_resource_violation/6` which
  # always raises; dialyzer correctly infers `no_return`. Same shape as
  # the other `handle_worker_outcome/5` clauses (heap kill, exit, raised)
  # which dialyzer accepts because they pattern-match — the timeout
  # clause was extracted into its own helper in Codex review #27 to
  # disambiguate yield-nil from shutdown-observed-exit.
  {"lib/crank/server.ex", :no_return}
]
