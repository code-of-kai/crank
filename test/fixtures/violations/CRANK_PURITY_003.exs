defmodule CrankFixture.Purity003 do
  use Crank

  @impl true
  def start(_), do: {:ok, :idle, %{}}

  @impl true
  def turn(_event, :idle, memory) do
    Logger.info("transitioning")
    {:next, :active, memory}
  end
end
