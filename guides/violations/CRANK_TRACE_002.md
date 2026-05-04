# CRANK_TRACE_002 — Process dictionary mutation during turn

## What triggers this

A traced `turn/3` modified the process dictionary. `Crank.PurityTrace` takes a `Process.get_keys/0` snapshot before and after the turn; any difference fires this code.

The static check (`CRANK_PURITY_006`) catches the literal `Process.put`, `Process.get`, `Process.delete`. `CRANK_TRACE_002` catches transitive cases: a helper that uses the process dict, a logger backend that stashes a token, anything `turn/3`'s body invoked indirectly.

```elixir
def turn(:tag, %Idle{}, memory) do
  MyApp.Telemetry.tag_request(memory.id)    # the helper writes Process.put internally
  {:next, %Tagged{}, memory}
end
```

## Why it's wrong

The process dictionary is hidden state. It doesn't appear in any function signature; you cannot tell from reading the code whether a function reads or writes it. Two replays of the same `(event, state, memory)` produce different results if the dict differed between them. Snapshot/resume drops the dict entirely. Test isolation breaks if a previous test left entries behind.

In a pure core, the rule is simple: every input is an explicit argument. The process dict is the worst kind of implicit input — invisible at the call site, persistent across calls, never serialised.

## How to fix

### Wrong

```elixir
defmodule MyApp.Telemetry do
  def tag_request(id) do
    Process.put(:current_request, id)
  end
end
```

### Right

```elixir
# Carry the value in memory — explicit, snapshotted, replayable.
def turn({:tag, id}, %Idle{}, memory) do
  {:next, %Tagged{}, %{memory | current_request: id}}
end
```

If the value really is process-scoped operational state (a request ID for downstream HTTP headers), it belongs in an adapter that runs in the gen_statem process — *outside* `turn/3`. The pure core sees a plain ID; the adapter wires it into the request headers when telemetry fires.

## How to suppress at this layer

Layer C — programmatic `:allow` opt. Source comments cannot suppress this code; attempting raises `CRANK_META_004`.

```elixir
test "machine that integrates with a library using process dict" do
  Crank.PropertyTest.assert_pure_turn(machine, events,
    allow: [
      {Process, :put, :_, reason: "OpenTelemetry context propagation; sandboxed"}
    ]
  )
end
```

Suppressing this is almost always the wrong move. Prefer fixing the helper.

## See also

- [`CRANK_PURITY_006`](CRANK_PURITY_006.md) — call-site detection.
- [Property testing](../property-testing.md).
- [Suppressions](../suppressions.md).
