defmodule Crank.StoppedError do
  @moduledoc """
  Raised when `Crank.crank/2` or `Crank.crank!/2` is called on a machine
  whose status is `{:stopped, reason}`.
  """

  defexception [:module, :state, :event, :reason]

  @impl true
  def message(%{module: module, state: state, event: event, reason: reason}) do
    "cannot crank #{inspect(module)} (in state #{inspect(state)}) " <>
      "with event #{inspect(event)}: machine is stopped (#{inspect(reason)})"
  end
end
