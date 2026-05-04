defmodule CrankFixture.Purity005 do
  use Crank

  @impl true
  def start(_), do: {:ok, :idle, %{}}

  @impl true
  def turn(_event, :idle, memory) do
    send(self(), :hello)
    {:next, :active, memory}
  end
end
