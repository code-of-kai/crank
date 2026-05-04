defmodule CrankFixture.Purity001 do
  use Crank

  @impl true
  def start(_), do: {:ok, :idle, %{}}

  @impl true
  def turn(_event, :idle, memory) do
    _ = Repo.insert!(%{foo: :bar})
    {:next, :active, memory}
  end
end
