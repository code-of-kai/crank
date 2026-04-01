defmodule Decidable.StoppedError do
  @moduledoc """
  Raised when `Decidable.transition/2` or `Decidable.transition!/2` is called
  on a machine whose status is `{:stopped, reason}`.
  """

  defexception [:module, :state, :event, :reason]

  @impl true
  def message(%{module: module, state: state, event: event, reason: reason}) do
    "cannot transition #{inspect(module)} (in state #{inspect(state)}) " <>
      "with event #{inspect(event)}: machine is stopped (#{inspect(reason)})"
  end
end
