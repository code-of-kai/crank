defmodule CrankFixture.Purity006 do
  use Crank

  @impl true
  def start(_), do: {:ok, :idle, %{}}

  @impl true
  def turn(_event, :idle, memory) do
    _ = :ets.lookup(:my_table, :key)
    {:next, :active, memory}
  end
end
