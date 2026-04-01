defmodule Rig.Machine do
  @moduledoc """
  The core data structure representing a finite state machine.

  A `%Rig.Machine{}` is a pure value — it holds the current state,
  accumulated data, and any effects produced by the last crank.
  It never executes side effects. The optional `Rig.Server` process
  adapter interprets and executes effects; in pure code, you
  inspect them directly.

  ## Fields

    * `:module` — the callback module implementing the `Rig` behaviour
    * `:state` — the current state (any term, typically an atom)
    * `:data` — arbitrary user data carried through cranks
    * `:effects` — effects returned by the most recent crank,
      stored as data for the caller or Server to interpret
    * `:status` — `:running` or `{:stopped, reason}`

  ## Parameterized types

  `t/0` is the generic type used inside Rig's own code. For precise
  typing in your own modules, use `t/2`:

      @spec get_machine() :: Rig.Machine.t(:locked | :unlocked, map())

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

  @typedoc "A reply action for synchronous calls."
  @type reply_action :: {:reply, GenServer.from(), term()}

  @typedoc "Event timeout — fires if no event arrives within the period."
  @type event_timeout ::
          {:timeout, non_neg_integer() | :infinity, term()}
          | {:timeout, non_neg_integer() | :infinity, term(), keyword()}

  @typedoc "State timeout — fires if the machine stays in this state for the period."
  @type state_timeout ::
          {:state_timeout, non_neg_integer() | :infinity, term()}
          | {:state_timeout, non_neg_integer() | :infinity, term(), keyword()}

  @typedoc "Named (generic) timeout — identified by a caller-chosen name."
  @type named_timeout ::
          {{:timeout, term()}, non_neg_integer() | :infinity, term()}
          | {{:timeout, term()}, non_neg_integer() | :infinity, term(), keyword()}

  @typedoc "Inject a synthetic event into the machine's own mailbox."
  @type next_event_action :: {:next_event, Rig.event_type(), term()}

  @typedoc """
  Any gen_statem action that can appear in an effects list.
  """
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

  @typedoc "The lifecycle status of the machine."
  @type status :: :running | {:stopped, reason :: term()}

  # ---------------------------------------------------------------------------
  # Machine type — generic and parameterized
  # ---------------------------------------------------------------------------

  @typedoc """
  A machine with specific state and data types.

  Use this in your own code for precise typing:

      @spec checkout_machine() :: Rig.Machine.t(:cart | :payment | :complete, Order.t())
  """
  @type t(state, data) :: %__MODULE__{
          module: module(),
          state: state,
          data: data,
          effects: [action()],
          status: status()
        }

  @typedoc "A machine with unparameterized (generic) state and data."
  @type t :: t(term(), term())
end
