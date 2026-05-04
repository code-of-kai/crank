defmodule CrankFixture.Purity002 do
  use Crank

  defp side_effect_helper, do: :ok

  @impl true
  def start(_), do: {:ok, :idle, %{}}

  @impl true
  def turn(_event, :idle, memory) do
    _ = side_effect_helper()
    {:next, :active, memory}
  end
end
