defmodule Rig.Examples.Door do
  @moduledoc false
  use Rig

  @impl true
  def init(_opts), do: {:ok, :locked, %{}}

  @impl true
  def handle_event(:locked, _, :unlock, data), do: {:next_state, :unlocked, data}
  def handle_event(:unlocked, _, :lock, data), do: {:next_state, :locked, data}
  def handle_event(:unlocked, _, :open, data), do: {:next_state, :opened, data}
  def handle_event(:opened, _, :close, data), do: {:next_state, :unlocked, data}
end

defmodule Rig.Examples.Turnstile do
  @moduledoc false
  use Rig

  @impl true
  def init(_opts), do: {:ok, :locked, %{coins: 0, passes: 0}}

  @impl true
  def handle_event(:locked, _, :coin, data) do
    {:next_state, :unlocked, %{data | coins: data.coins + 1}}
  end

  def handle_event(:unlocked, _, :push, data) do
    {:next_state, :locked, %{data | passes: data.passes + 1}}
  end

  def handle_event(:unlocked, _, :coin, data) do
    {:keep_state, %{data | coins: data.coins + 1}}
  end

  def handle_event(:locked, _, :push, _data) do
    :keep_state_and_data
  end
end

defmodule Rig.Examples.Order do
  @moduledoc """
  A non-trivial, total state machine for testing.

  5 states, 8 events, effects, on_enter. Every event is handled in
  every state (total function) — invalid events in a given state are
  explicitly ignored via `:keep_state_and_data`. This makes it safe
  for property testing with random event sequences.

  State diagram:

      pending ──pay──→ paid ──ship──→ shipped ──deliver──→ delivered
        │                │                │
        └──cancel──→  cancelled  ←──cancel─┘
                         ↑
        (any state)──cancel──→ cancelled

  All states handle :note (appends to notes list, keep_state).
  :paid and :shipped return effects (state timeouts).
  on_enter/3 logs every transition.
  """
  use Rig

  @states [:pending, :paid, :shipped, :delivered, :cancelled]
  @events [:pay, :ship, :deliver, :cancel, :note, :rush, :refund, :noop]

  @doc "All valid states."
  def states, do: @states

  @doc "All valid events."
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
  def handle_event(:pending, _, :pay, data) do
    {:next_state, :paid, %{data | transitions: data.transitions + 1},
     [{:state_timeout, 86_400_000, :payment_confirmation}]}
  end

  def handle_event(:pending, _, :cancel, data) do
    {:next_state, :cancelled, %{data | transitions: data.transitions + 1}}
  end

  # --- paid ---
  def handle_event(:paid, _, :ship, data) do
    {:next_state, :shipped, %{data | transitions: data.transitions + 1},
     [{:state_timeout, 172_800_000, :delivery_deadline}]}
  end

  def handle_event(:paid, _, :cancel, data) do
    {:next_state, :cancelled, %{data | transitions: data.transitions + 1}}
  end

  def handle_event(:paid, _, :rush, data) do
    {:keep_state, %{data | notes: ["rush requested" | data.notes]},
     [{:state_timeout, 3_600_000, :rush_reminder}]}
  end

  # --- shipped ---
  def handle_event(:shipped, _, :deliver, data) do
    {:next_state, :delivered, %{data | transitions: data.transitions + 1}}
  end

  def handle_event(:shipped, _, :cancel, data) do
    {:next_state, :cancelled, %{data | transitions: data.transitions + 1}}
  end

  # --- note (any state) ---
  def handle_event(_state, _, :note, data) do
    {:keep_state, %{data | notes: ["note" | data.notes]}}
  end

  # --- refund (only delivered) ---
  def handle_event(:delivered, _, :refund, data) do
    {:next_state, :cancelled, %{data | transitions: data.transitions + 1,
                                       notes: ["refunded" | data.notes]}}
  end

  # --- noop (any state) ---
  def handle_event(_state, _, :noop, _data) do
    :keep_state_and_data
  end

  # --- catch-all for events that don't apply in current state ---
  # Total function: every (state, event) pair is handled.
  def handle_event(_state, _, _event, _data) do
    :keep_state_and_data
  end

  @impl true
  def on_enter(old_state, new_state, data) do
    {:keep_state, %{data | enter_log: [{old_state, new_state} | data.enter_log]}}
  end
end
