defmodule Crank.Examples.Door do
  @moduledoc """
  A door with three states and four transitions. No memory, no wants.

      locked ──unlock──→ unlocked ──open──→ opened
         ↑                 │                  │
         └─────lock────────┘                  │
                 ↑                            │
                 └─────────close──────────────┘
  """
  use Crank

  @impl true
  def start(_opts), do: {:ok, :locked, %{}}

  @impl true
  def turn(:unlock, :locked, memory), do: {:next, :unlocked, memory}
  def turn(:lock, :unlocked, memory), do: {:next, :locked, memory}
  def turn(:open, :unlocked, memory), do: {:next, :opened, memory}
  def turn(:close, :opened, memory), do: {:next, :unlocked, memory}
end

defmodule Crank.Examples.Turnstile do
  @moduledoc """
  A turnstile with two states. Keeps running counters in memory.

      locked ──coin──→ unlocked ──push──→ locked
      (push ignored)   (coin adds to balance, stays)
  """
  use Crank

  @impl true
  def start(_opts), do: {:ok, :locked, %{coins: 0, passes: 0}}

  @impl true
  def turn(:coin, :locked, memory) do
    {:next, :unlocked, %{memory | coins: memory.coins + 1}}
  end

  def turn(:push, :unlocked, memory) do
    {:next, :locked, %{memory | passes: memory.passes + 1}}
  end

  def turn(:coin, :unlocked, memory) do
    {:stay, %{memory | coins: memory.coins + 1}}
  end

  def turn(:push, :locked, _memory), do: :stay
end

defmodule Crank.Examples.VendingMachine do
  @moduledoc """
  A vending machine showing the Moore discipline end-to-end:
  `c:Crank.turn/3` handles only state, `c:Crank.wants/2` declares timeouts
  per state, `c:Crank.reading/2` projects what external callers see.

      idle ──coin──→ accepting ──select──→ dispensing
       ↑                │                      │
       └──refund────────┘                      │
                                ┌──dispensed───┘
                                ↓
                              idle
  """
  use Crank

  @impl true
  def start(opts) do
    {:ok, :idle, %{price: opts[:price] || 100, balance: 0, selection: nil}}
  end

  @impl true
  def turn({:coin, amount}, :idle, memory) do
    {:next, :accepting, %{memory | balance: amount}}
  end

  def turn({:coin, amount}, :accepting, memory) do
    {:stay, %{memory | balance: memory.balance + amount}}
  end

  def turn({:select, item}, :accepting, %{balance: b, price: p} = memory) when b >= p do
    {:next, :dispensing, %{memory | selection: item}}
  end

  def turn(:dispensed, :dispensing, memory) do
    {:next, :idle, %{memory | balance: 0, selection: nil}}
  end

  def turn(:refund, :accepting, memory) do
    {:next, :idle, %{memory | balance: 0}}
  end

  # Moore: timeouts attach to states, not to the edges that arrived there.
  @impl true
  def wants(:accepting, _memory), do: [{:after, 60_000, :timeout_refund}]
  def wants(:dispensing, _memory), do: [{:after, 5_000, :jam}]
  def wants(_state, _memory), do: []

  # Moore: what callers see is f(state, memory). No edge-coupling.
  @impl true
  def reading(:idle, _memory), do: %{status: :idle}
  def reading(:accepting, memory), do: %{status: :accepting, balance: memory.balance}
  def reading(:dispensing, memory), do: %{status: :dispensing, item: memory.selection}
end

defmodule Crank.Examples.Order do
  @moduledoc """
  An order that moves through five states. Every (state, event) pair is
  handled — the catch-all makes this a total function, which property
  tests need when they fire random events.

      pending ──pay──→ paid ──ship──→ shipped ──deliver──→ delivered
        │               │               │
        └──cancel──→  cancelled  ←──cancel──┘
                         ↑
          (any state)──cancel──→ cancelled

  Long-running timeouts — payment confirmation, delivery deadline — are
  declared by `c:Crank.wants/2` per state. The Mealy version attached
  them to the transitions that arrived. Moore attaches them to the states
  that have them.
  """
  use Crank

  @states [:pending, :paid, :shipped, :delivered, :cancelled]
  @events [:pay, :ship, :deliver, :cancel, :note, :refund, :noop]

  @doc "All valid states."
  def states, do: @states

  @doc "All valid events."
  def events, do: @events

  @impl true
  def start(opts) do
    {:ok, :pending,
     %{
       order_id: opts[:order_id] || 0,
       total: opts[:total] || 100,
       notes: [],
       transitions: 0
     }}
  end

  @impl true
  def turn(:pay, :pending, memory) do
    {:next, :paid, bump(memory)}
  end

  def turn(:cancel, :pending, memory) do
    {:next, :cancelled, bump(memory)}
  end

  def turn(:ship, :paid, memory) do
    {:next, :shipped, bump(memory)}
  end

  def turn(:cancel, :paid, memory) do
    {:next, :cancelled, bump(memory)}
  end

  def turn(:deliver, :shipped, memory) do
    {:next, :delivered, bump(memory)}
  end

  def turn(:cancel, :shipped, memory) do
    {:next, :cancelled, bump(memory)}
  end

  def turn(:refund, :delivered, memory) do
    {:next, :cancelled, bump(%{memory | notes: ["refunded" | memory.notes]})}
  end

  def turn(:note, _state, memory) do
    {:stay, %{memory | notes: ["note" | memory.notes]}}
  end

  def turn(:noop, _state, _memory), do: :stay

  # NOTE: This catch-all exists specifically so random event sequences in
  # property tests don't crash the machine. Production FSMs should NOT include
  # a catch-all — unhandled events should raise `FunctionClauseError` so
  # misbehaving callers are surfaced loudly. Let-it-crash is the default for
  # real code; totalising is a property-testing affordance.
  def turn(_event, _state, _memory), do: :stay

  @impl true
  def wants(:paid, _memory), do: [{:after, 86_400_000, :payment_confirmation}]
  def wants(:shipped, _memory), do: [{:after, 172_800_000, :delivery_deadline}]
  def wants(_state, _memory), do: []

  defp bump(memory), do: %{memory | transitions: memory.transitions + 1}
end

defmodule Crank.Examples.Submission do
  @moduledoc """
  A submission workflow where each state is its own struct. The struct
  carries only the fields that exist in that state. A `%Quoted{}` can't
  have a `violations` field — the struct doesn't define one.

      Validating ──validate──→ Quoted ──bind──→ Bound
           │                     │
           └──decline──→ Declined ←──decline──┘

  Scott Wlaschin's *Making Illegal States Unrepresentable*. Crank supports
  this out of the box because `state` is `term()` and struct-matching in
  `c:Crank.turn/3` naturally splits by state.
  """
  use Crank

  defmodule Validating do
    @moduledoc false
    @type t :: %__MODULE__{violations: [atom()]}
    defstruct violations: []
  end

  defmodule Quoted do
    @moduledoc false
    @type t :: %__MODULE__{quotes: [map()], selected: map() | nil}
    defstruct quotes: [], selected: nil
  end

  defmodule Bound do
    @moduledoc false
    @type t :: %__MODULE__{quote: map() | nil, bound_at: atom() | nil}
    defstruct quote: nil, bound_at: nil
  end

  defmodule Declined do
    @moduledoc false
    @type t :: %__MODULE__{reason: term()}
    defstruct reason: nil
  end

  @typedoc "One of four state structs."
  @type state :: Validating.t() | Quoted.t() | Bound.t() | Declined.t()

  @typedoc "Cross-state memory: parameters and an audit log."
  @type memory :: %{parameters: map(), audit: [term()]}

  @doc "All state struct modules."
  @spec state_modules() :: [module()]
  def state_modules, do: [Validating, Quoted, Bound, Declined]

  @doc "Atom events (tuple events generated separately in property tests)."
  @spec events() :: [atom()]
  def events, do: [:validate, :bind, :decline, :note, :noop]

  @impl true
  @spec start(keyword()) :: {:ok, state(), memory()}
  def start(opts) do
    {:ok, %Validating{}, %{parameters: opts[:parameters] || %{}, audit: []}}
  end

  @impl true
  # ── Validating ──
  def turn({:violation, v}, %Validating{} = s, memory) do
    {:next, %Validating{s | violations: [v | s.violations]}, memory}
  end

  def turn(:validate, %Validating{violations: []}, memory) do
    {:next, %Quoted{}, memory}
  end

  def turn(:validate, %Validating{violations: vs}, memory) do
    {:next, %Declined{reason: {:violations, vs}}, memory}
  end

  def turn(:decline, %Validating{}, memory) do
    {:next, %Declined{reason: :manual}, memory}
  end

  # ── Quoted ──
  def turn({:add_quote, q}, %Quoted{} = s, memory) do
    {:next, %Quoted{s | quotes: [q | s.quotes]}, memory}
  end

  def turn({:select, idx}, %Quoted{quotes: quotes} = s, memory) when quotes != [] do
    safe_idx = rem(abs(idx), length(quotes))
    {:next, %Quoted{s | selected: Enum.at(quotes, safe_idx)}, memory}
  end

  def turn(:bind, %Quoted{selected: sel}, memory) when sel != nil do
    {:next, %Bound{quote: sel, bound_at: :now}, memory}
  end

  def turn(:decline, %Quoted{}, memory) do
    {:next, %Declined{reason: :manual}, memory}
  end

  # ── Any state ──
  def turn(:note, _state, memory) do
    {:stay, %{memory | audit: [:note | memory.audit]}}
  end

  def turn(:noop, _state, _memory), do: :stay

  # Property-test affordance — see `Crank.Examples.Order` for the equivalent
  # note. Production modules should let unhandled events raise.
  def turn(_event, _state, _memory), do: :stay
end
