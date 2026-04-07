defmodule Crank.Machine do
  @moduledoc """
  The struct that `Crank.crank/2` takes and returns.

  `%Crank.Machine{}` carries five fields:

    * `:module` -- the callback module that defines the machine's transitions
    * `:state` -- the current state (any term: atoms, structs, tagged tuples)
    * `:data` -- data shared across all states, carried through every crank
    * `:effects` -- side effects from the last crank, stored as inert data
    * `:status` -- `:running` or `{:stopped, reason}`

  The struct never executes side effects. It stores them. `Crank.Server`
  interprets and executes effects when the machine runs as a process. In
  pure code, inspect them directly.

  Each call to `Crank.crank/2` replaces the effects list. Effects from
  earlier cranks don't accumulate.

  ## Parameterized types

  `t/0` is the generic type. For precise typing in your own modules,
  use `t/2` with concrete state and data types:

      @spec get_machine() :: Crank.Machine.t(:locked | :unlocked, map())

  See `Crank.Examples.Submission` for the struct-per-state pattern,
  where each state is its own struct.
  """

  @enforce_keys [:module, :state, :data]
  defstruct [
    :module,
    :state,
    :data,
    effects: [],
    status: :running
  ]

  # ---------------------------------------------------------------------------
  # Action types — mirrors :gen_statem action vocabulary
  # ---------------------------------------------------------------------------

  @typedoc "Sends a reply to a caller waiting on `Crank.Server.call/3`."
  @type reply_action :: {:reply, GenServer.from(), term()}

  @typedoc "Fires if no event arrives within the given period."
  @type event_timeout ::
          {:timeout, non_neg_integer() | :infinity, term()}
          | {:timeout, non_neg_integer() | :infinity, term(), keyword()}

  @typedoc "Fires if the machine stays in the current state for the given period."
  @type state_timeout ::
          {:state_timeout, non_neg_integer() | :infinity, term()}
          | {:state_timeout, non_neg_integer() | :infinity, term(), keyword()}

  @typedoc "A timeout identified by a caller-chosen name. Multiple named timeouts can run concurrently."
  @type named_timeout ::
          {{:timeout, term()}, non_neg_integer() | :infinity, term()}
          | {{:timeout, term()}, non_neg_integer() | :infinity, term(), keyword()}

  @typedoc "Injects a new event into the machine's own event queue."
  @type next_event_action :: {:next_event, Crank.event_type(), term()}

  @typedoc "Any `gen_statem` action that can appear in an effects list."
  @type action ::
          :postpone
          | :hibernate
          | reply_action()
          | event_timeout()
          | state_timeout()
          | named_timeout()
          | next_event_action()

  # ---------------------------------------------------------------------------
  # Status type
  # ---------------------------------------------------------------------------

  @typedoc "`:running` while the machine accepts events. `{:stopped, reason}` after it shuts down."
  @type status :: :running | {:stopped, reason :: term()}

  # ---------------------------------------------------------------------------
  # Machine type — generic and parameterized
  # ---------------------------------------------------------------------------

  @typedoc """
  A machine parameterized by its state and data types.

      @spec checkout_machine() :: Crank.Machine.t(:cart | :payment | :complete, Order.t())
  """
  @type t(state, data) :: %__MODULE__{
          module: module(),
          state: state,
          data: data,
          effects: [action()],
          status: status()
        }

  @typedoc "A machine with generic (unparameterized) state and data types."
  @type t :: t(term(), term())
end
