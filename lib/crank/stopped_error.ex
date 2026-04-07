defmodule Crank.StoppedError do
  @moduledoc """
  Raised when `Crank.crank/2` or `Crank.crank!/2` receives a machine
  that has already stopped.

  A machine stops when a `handle/3` clause returns `{:stop, reason, data}`.
  After that, no more events can be processed. Attempting to crank a
  stopped machine raises this error with the module, current state,
  attempted event, and stop reason.
  """

  defexception [:module, :state, :event, :reason]

  @impl true
  def message(%{module: module, state: state, event: event, reason: reason}) do
    "cannot crank #{inspect(module)} (in state #{inspect(state)}) " <>
      "with event #{inspect(event)}: machine is stopped (#{inspect(reason)})"
  end
end
