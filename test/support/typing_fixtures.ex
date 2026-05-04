defmodule Crank.TypingFixtures.IdleState do
  @moduledoc false
  defstruct []
  @type t :: %__MODULE__{}
end

defmodule Crank.TypingFixtures.ActiveState do
  @moduledoc false
  defstruct [:since]
  @type t :: %__MODULE__{since: integer()}
end

defmodule Crank.TypingFixtures.Memory do
  @moduledoc false
  defstruct [:counter]
  @type t :: %__MODULE__{counter: integer()}
end

defmodule Crank.TypingFixtures.Machine do
  @moduledoc false
  use Crank,
    states: [Crank.TypingFixtures.IdleState, Crank.TypingFixtures.ActiveState],
    memory: Crank.TypingFixtures.Memory

  @impl true
  def start(_) do
    {:ok, %Crank.TypingFixtures.IdleState{}, %Crank.TypingFixtures.Memory{counter: 0}}
  end

  @impl true
  def turn(:tick, %Crank.TypingFixtures.IdleState{}, memory) do
    {:next, %Crank.TypingFixtures.ActiveState{since: 0}, memory}
  end

  def turn(:keep, _state, memory), do: {:stay, memory}
  def turn(:halt, _state, memory), do: {:stop, :normal, memory}
end

defmodule Crank.TypingFixtures.MachineWithoutOpts do
  @moduledoc false
  use Crank

  @impl true
  def start(_), do: {:ok, :idle, %{}}

  @impl true
  def turn(_event, _state, memory), do: {:stay, memory}
end

defmodule Crank.TypingFixtures.PureMemory do
  @moduledoc false
  defstruct [:value, :name]
  @type t :: %__MODULE__{value: integer(), name: String.t()}
end

defmodule Crank.TypingFixtures.MemoryWithFunction do
  @moduledoc """
  Negative fixture: this struct's typespec contains a `function/0` field type,
  which is forbidden in memory because it makes memory unserializable. The
  CRANK_TYPE_002 check must catch this when a `use Crank, memory: ...`
  module declares this struct as its memory.
  """
  defstruct [:handler]
  @type t :: %__MODULE__{handler: (-> :ok)}
end

defmodule Crank.TypingFixtures.MemoryWithModule do
  @moduledoc """
  Negative fixture: this struct's typespec uses `module/0` (the predefined
  type for atoms-that-are-modules). Carrying module values in memory is
  rejected because it conflates data with behaviour.
  """
  defstruct [:adapter]
  @type t :: %__MODULE__{adapter: module()}
end
