defmodule Crank.Examples.Door do
  @moduledoc false
  use Crank

  @impl true
  def init(_opts), do: {:ok, :locked, %{}}

  @impl true
  def handle_event(_, :unlock, :locked, data), do: {:next_state, :unlocked, data}
  def handle_event(_, :lock, :unlocked, data), do: {:next_state, :locked, data}
  def handle_event(_, :open, :unlocked, data), do: {:next_state, :opened, data}
  def handle_event(_, :close, :opened, data), do: {:next_state, :unlocked, data}
end

defmodule Crank.Examples.Turnstile do
  @moduledoc false
  use Crank

  @impl true
  def init(_opts), do: {:ok, :locked, %{coins: 0, passes: 0}}

  @impl true
  def handle_event(_, :coin, :locked, data) do
    {:next_state, :unlocked, %{data | coins: data.coins + 1}}
  end

  def handle_event(_, :push, :unlocked, data) do
    {:next_state, :locked, %{data | passes: data.passes + 1}}
  end

  def handle_event(_, :coin, :unlocked, data) do
    {:keep_state, %{data | coins: data.coins + 1}}
  end

  def handle_event(_, :push, :locked, _data) do
    :keep_state_and_data
  end
end

defmodule Crank.Examples.Order do
  @moduledoc """
  An order that moves through five states: pending, paid, shipped,
  delivered, and cancelled.

      pending ──pay──→ paid ──ship──→ shipped ──deliver──→ delivered
        │                │                │
        └──cancel──→  cancelled  ←──cancel─┘
                         ↑
        (any state)──cancel──→ cancelled

  Every event is handled in every state. Invalid events in a given
  state return `:keep_state_and_data` -- they're explicitly ignored,
  not silently dropped. This makes the machine a total function
  (every input produces a defined output), which is what property
  testing with random event sequences requires.

  The `:paid` and `:shipped` states return state timeout effects.
  `on_enter/3` logs every transition. All states accept `:note`.
  """
  use Crank

  @states [:pending, :paid, :shipped, :delivered, :cancelled]
  @events [:pay, :ship, :deliver, :cancel, :note, :rush, :refund, :noop]

  @doc "Returns the list of all valid state atoms."
  def states, do: @states

  @doc "Returns the list of all valid event atoms."
  def events, do: @events

  @impl true
  def init(opts) do
    {:ok, :pending, %{
      order_id: opts[:order_id] || 0,
      notes: [],
      total: opts[:total] || 100,
      transitions: 0,
      enter_log: []
    }}
  end

  @impl true
  # --- pending ---
  def handle_event(_, :pay, :pending, data) do
    {:next_state, :paid, %{data | transitions: data.transitions + 1},
     [{:state_timeout, 86_400_000, :payment_confirmation}]}
  end

  def handle_event(_, :cancel, :pending, data) do
    {:next_state, :cancelled, %{data | transitions: data.transitions + 1}}
  end

  # --- paid ---
  def handle_event(_, :ship, :paid, data) do
    {:next_state, :shipped, %{data | transitions: data.transitions + 1},
     [{:state_timeout, 172_800_000, :delivery_deadline}]}
  end

  def handle_event(_, :cancel, :paid, data) do
    {:next_state, :cancelled, %{data | transitions: data.transitions + 1}}
  end

  def handle_event(_, :rush, :paid, data) do
    {:keep_state, %{data | notes: ["rush requested" | data.notes]},
     [{:state_timeout, 3_600_000, :rush_reminder}]}
  end

  # --- shipped ---
  def handle_event(_, :deliver, :shipped, data) do
    {:next_state, :delivered, %{data | transitions: data.transitions + 1}}
  end

  def handle_event(_, :cancel, :shipped, data) do
    {:next_state, :cancelled, %{data | transitions: data.transitions + 1}}
  end

  # --- note (any state) ---
  def handle_event(_, :note, _state, data) do
    {:keep_state, %{data | notes: ["note" | data.notes]}}
  end

  # --- refund (only delivered) ---
  def handle_event(_, :refund, :delivered, data) do
    {:next_state, :cancelled, %{data | transitions: data.transitions + 1,
                                       notes: ["refunded" | data.notes]}}
  end

  # --- noop (any state) ---
  def handle_event(_, :noop, _state, _data) do
    :keep_state_and_data
  end

  # --- catch-all for events that don't apply in current state ---
  # Total function: every (state, event) pair is handled.
  def handle_event(_, _event, _state, _data) do
    :keep_state_and_data
  end

  @impl true
  def on_enter(old_state, new_state, data) do
    {:keep_state, %{data | enter_log: [{old_state, new_state} | data.enter_log]}}
  end
end

defmodule Crank.Examples.Submission do
  @moduledoc """
  A submission workflow where each state is its own struct.

  `%Validating{}` has a `violations` field. `%Quoted{}` has `quotes`
  and `selected`. `%Bound{}` has `quote` and `bound_at`. Each struct
  carries only the fields that exist in that state. A `%Quoted{}`
  can't have a `violations` field because the struct doesn't define
  one. The compiler enforces this.

  This is Scott Wlaschin's "Making Illegal States Unrepresentable"
  pattern. It works in Crank without any special support because
  `Machine.state` is `term()` -- structs are valid states.

      Validating ──validate──→ Quoted ──bind──→ Bound
          │                      │
          └──decline──→ Declined ←──decline──┘

  State structs carry state-specific data. The `data` map carries
  cross-cutting concerns shared across all states (parameters, audit).

  When a field on the current state struct changes (adding a violation
  to `%Validating{}`), the return is `{:next_state, %Validating{updated}, data}`.
  The state value changed, so it's a state transition. `:keep_state`
  is reserved for changes to `data` only.

  Every event is handled in every state (total function).

  ## Type annotations

  The `@type state` union below lists every valid state struct. Today
  these annotations serve as documentation and Dialyzer input. When
  Elixir's set-theoretic type system (introduced in v1.17) can check
  them, unhandled state variants will produce compiler warnings
  without any code changes.
  """
  use Crank

  # --- State structs (each state owns its data) ---

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

  # --- Type union: the set of all valid states ---

  @typedoc "One of the four state structs: `Validating`, `Quoted`, `Bound`, or `Declined`."
  @type state :: Validating.t() | Quoted.t() | Bound.t() | Declined.t()

  @typedoc "Data shared across all states: parameters and an audit trail."
  @type data :: %{parameters: map(), audit: [term()]}

  @typedoc "Events the submission machine accepts."
  @type event ::
          {:violation, atom()}
          | :validate
          | {:add_quote, map()}
          | {:select, non_neg_integer()}
          | :bind
          | :decline
          | :note
          | :noop

  @doc "Returns the list of all state struct modules."
  @spec state_modules() :: [module()]
  def state_modules, do: [Validating, Quoted, Bound, Declined]

  @doc "Returns the list of atom events. Tuple events (`:violation`, `:add_quote`, `:select`) are generated separately in tests."
  @spec events() :: [atom()]
  def events, do: [:validate, :bind, :decline, :note, :noop]

  @impl true
  @spec init(keyword()) :: {:ok, state(), data()}
  def init(opts) do
    {:ok, %Validating{}, %{parameters: opts[:parameters] || %{}, audit: []}}
  end

  @impl true
  # --- Validating ---
  @spec handle_event(Crank.event_type(), event(), state(), data()) :: Crank.handle_event_result()
  def handle_event(_, {:violation, v}, %Validating{} = s, data) do
    {:next_state, %Validating{s | violations: [v | s.violations]}, data}
  end

  def handle_event(_, :validate, %Validating{violations: []}, data) do
    {:next_state, %Quoted{}, data}
  end

  def handle_event(_, :validate, %Validating{violations: vs}, data) do
    {:next_state, %Declined{reason: {:violations, vs}}, data}
  end

  def handle_event(_, :decline, %Validating{}, data) do
    {:next_state, %Declined{reason: :manual}, data}
  end

  # --- Quoted ---
  def handle_event(_, {:add_quote, q}, %Quoted{} = s, data) do
    {:next_state, %Quoted{s | quotes: [q | s.quotes]}, data}
  end

  def handle_event(_, {:select, idx}, %Quoted{quotes: quotes} = s, data)
      when quotes != [] do
    safe_idx = rem(abs(idx), length(quotes))
    {:next_state, %Quoted{s | selected: Enum.at(quotes, safe_idx)}, data}
  end

  def handle_event(_, :bind, %Quoted{selected: sel}, data) when sel != nil do
    {:next_state, %Bound{quote: sel, bound_at: :now}, data}
  end

  def handle_event(_, :decline, %Quoted{}, data) do
    {:next_state, %Declined{reason: :manual}, data}
  end

  # --- note (any state, modifies data only) ---
  def handle_event(_, :note, _state, data) do
    {:keep_state, %{data | audit: [:note | data.audit]}}
  end

  # --- noop (any state) ---
  def handle_event(_, :noop, _state, _data) do
    :keep_state_and_data
  end

  # --- catch-all: total function ---
  def handle_event(_, _event, _state, _data) do
    :keep_state_and_data
  end

  @impl true
  @spec on_enter(state(), state(), data()) :: Crank.on_enter_result()
  def on_enter(old_state, new_state, data) do
    {:keep_state, %{data | audit: [{:enter, old_state.__struct__, new_state.__struct__} | data.audit]}}
  end
end
