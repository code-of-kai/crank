defmodule Decidable.Machine do
  @moduledoc """
  The core data structure representing a finite state machine.

  A `%Decidable.Machine{}` is a pure value — it holds the current state,
  accumulated data, and any actions produced by the last transition.
  It never executes side effects. The optional `Decidable.Server` process
  adapter interprets and executes pending actions; in pure code, you
  inspect them directly.

  ## Fields

    * `:module` — the callback module implementing the `Decidable` behaviour
    * `:state` — the current state (any term, typically an atom)
    * `:data` — arbitrary user data carried through transitions
    * `:pending_actions` — actions returned by the most recent transition,
      stored as data for the caller or Server to interpret
    * `:status` — `:running` or `{:stopped, reason}`

  """

  @enforce_keys [:module, :state, :data]
  defstruct [
    :module,
    :state,
    :data,
    pending_actions: [],
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
          pending_actions: [action()],
          status: :running | {:stopped, term()}
        }
end
