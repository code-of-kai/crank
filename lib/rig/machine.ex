defmodule Rig.Machine do
  @moduledoc """
  The core data structure representing a finite state machine.

  A `%Rig.Machine{}` is a pure value — it holds the current state,
  accumulated data, and any effects produced by the last step.
  It never executes side effects. The optional `Rig.Runner` process
  adapter interprets and executes effects; in pure code, you
  inspect them directly.

  ## Fields

    * `:module` — the callback module implementing the `Rig` behaviour
    * `:state` — the current state (any term, typically an atom)
    * `:data` — arbitrary user data carried through steps
    * `:effects` — effects returned by the most recent step,
      stored as data for the caller or Runner to interpret
    * `:status` — `:running` or `{:stopped, reason}`

  """

  @enforce_keys [:module, :state, :data]
  defstruct [
    :module,
    :state,
    :data,
    effects: [],
    status: :running
  ]

  @type action ::
          :postpone
          | :hibernate
          | {:reply, GenServer.from(), term()}
          | {:state_timeout, non_neg_integer() | :infinity, term()}
          | {:state_timeout, non_neg_integer() | :infinity, term(), keyword()}
          | {{:timeout, term()}, non_neg_integer() | :infinity, term()}
          | {{:timeout, term()}, non_neg_integer() | :infinity, term(), keyword()}
          | {:timeout, non_neg_integer() | :infinity, term()}
          | {:timeout, non_neg_integer() | :infinity, term(), keyword()}
          | {:next_event, term(), term()}

  @type t :: %__MODULE__{
          module: module(),
          state: term(),
          data: term(),
          effects: [action()],
          status: :running | {:stopped, term()}
        }
end
