defmodule Crank.StoppedError do
  @moduledoc """
  Raised when `Crank.turn/2` or `Crank.turn!/2` is called on a machine
  whose engine is off. A machine's engine stops when `c:Crank.turn/3`
  returns `{:stop, reason, memory}`. Once stopped, no further events
  are accepted.
  """

  defexception [:module, :state, :event, :reason]

  @impl true
  def message(%{module: module, state: state, event: event, reason: reason}) do
    "cannot turn #{inspect(module)} (in state #{inspect(state)}) " <>
      "with event #{inspect(event)}: engine is off (#{inspect(reason)})"
  end
end
