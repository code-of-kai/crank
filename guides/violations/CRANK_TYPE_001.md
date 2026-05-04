# CRANK_TYPE_001 — Unknown memory field

## What triggers this

A struct-update or struct-literal references a field that is not declared in the memory struct's `defstruct`. This is caught natively by Elixir at compile time as part of struct semantics — Crank's contribution is to surface the catalog code and link the diagnostic into the same reporting pipeline.

```elixir
defmodule MyApp.VendingMemory do
  defstruct [:price, :balance, :selection]
end

def turn({:select, item}, %Accepting{}, memory) do
  {:next, %Dispensing{}, %{memory | discount: 5}}    # CRANK_TYPE_001 — :discount not declared
end
```

The compiler rejects `%{memory | discount: 5}` and `%MyApp.VendingMemory{discount: 5}` outright. *(Track A implementation: the macro form in 1.7 verifies this is active and enforces it on Crank-managed memory structs.)*

## Why it's wrong

The whole point of struct-per-state and a tightly-typed memory is that adding a new field is a deliberate act, not an accident. If the field is misspelled, the compiler should reject it, full stop. If a new field is genuinely needed, it should be added to the `defstruct` (and to the typespec) so the type union stays honest.

Field-*type* mismatches (assigning a string to an integer-declared field) are a separate concern handled by Dialyzer warnings, tracked in the [ROADMAP](../../ROADMAP.md) under `CRANK_TYPE_001_DIALYZER`. `CRANK_TYPE_001` covers field-*name* validation only — the part Elixir's compiler enforces today, with no Dialyzer pass required.

## How to fix

### Wrong

```elixir
defmodule MyApp.VendingMemory do
  defstruct [:price, :balance, :selection]
end

def turn({:select, item}, %Accepting{}, memory) do
  {:next, %Dispensing{}, %{memory | discount: 5}}
end
```

### Right

```elixir
# Add the field to defstruct (and to the typespec):
defmodule MyApp.VendingMemory do
  defstruct [:price, :balance, :selection, discount: 0]

  @type t :: %__MODULE__{
    price: non_neg_integer(),
    balance: non_neg_integer(),
    selection: String.t() | nil,
    discount: non_neg_integer()
  }
end
```

Or, if `discount` belongs to one specific state rather than to memory, put it on that state's struct: `%Dispensing{discount: 5}` and stop carrying it in `memory`.

## How to suppress at this layer

Layer A — source-adjacent comment. Reserved for genuinely transitional cases; the cleaner fix is almost always to add the field.

```elixir
# crank-allow: CRANK_TYPE_001
# reason: scratch field used only in :test env; removed after PR #4423 merges
%{memory | scratch: 1}
```

## See also

- [Typing state and memory](../typing-state-and-memory.md) — the discipline behind struct-per-state.
- [`CRANK_TYPE_002`](CRANK_TYPE_002.md), [`CRANK_TYPE_003`](CRANK_TYPE_003.md) — sibling type-level checks.
- [Suppressions](../suppressions.md).
