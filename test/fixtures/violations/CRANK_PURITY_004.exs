defmodule CrankFixture.Purity004 do
  use Crank

  @impl true
  def start(_), do: {:ok, :idle, %{}}

  @impl true
  def turn(_event, :idle, memory) do
    now = DateTime.utc_now()
    {:next, :active, Map.put(memory, :now, now)}
  end
end
