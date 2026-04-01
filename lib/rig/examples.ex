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
