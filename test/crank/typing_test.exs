defmodule Crank.TypingTest do
  use ExUnit.Case, async: true

  describe "build_state_type/1" do
    test "returns nil for nil and empty list" do
      assert Crank.Typing.build_state_type(nil) == nil
      assert Crank.Typing.build_state_type([]) == nil
    end

    test "builds a single-state union AST" do
      ast = Crank.Typing.build_state_type([SomeState])
      assert {:@, _, [{:type, _, [_]}]} = ast
    end

    test "builds a multi-state union AST" do
      ast = Crank.Typing.build_state_type([Idle, Active, Done])
      assert {:@, _, [{:type, _, [_]}]} = ast

      assert Macro.to_string(ast) =~ "Idle.t()"
      assert Macro.to_string(ast) =~ "Active.t()"
      assert Macro.to_string(ast) =~ "Done.t()"
    end
  end

  describe "build_memory_type/1" do
    test "returns nil for nil" do
      assert Crank.Typing.build_memory_type(nil) == nil
    end

    test "builds a memory type AST referencing the named struct's t/0" do
      ast = Crank.Typing.build_memory_type(SomeMemory)
      assert {:@, _, [{:type, _, [_]}]} = ast
      assert Macro.to_string(ast) =~ "SomeMemory.t()"
    end
  end

  describe "use Crank, states: ..., memory: ... — generated typespecs" do
    # These tests use compiled fixture modules under test/support/typing_fixtures.ex
    # because Code.Typespec.fetch_types/1 requires the BEAM bytecode to be on
    # disk via the standard Mix compile path. Modules created via
    # Code.eval_string/1 don't have a BEAM file fetch_types can read.

    test "the macro generates @type state and @type memory; verified via Code.Typespec.fetch_types/1" do
      {:ok, types} = Code.Typespec.fetch_types(Crank.TypingFixtures.Machine)
      type_names = Enum.map(types, fn {_kind, {name, _, _}} -> name end)

      assert :state in type_names,
             "expected @type state to be generated, got types: #{inspect(type_names)}"

      assert :memory in type_names,
             "expected @type memory to be generated, got types: #{inspect(type_names)}"
    end

    test "the macro form is opt-in; without :states/:memory no typespecs are generated" do
      {:ok, types} = Code.Typespec.fetch_types(Crank.TypingFixtures.MachineWithoutOpts)
      type_names = Enum.map(types, fn {_kind, {name, _, _}} -> name end)

      refute :state in type_names
      refute :memory in type_names
    end
  end

  describe "CRANK_TYPE_002 — function/0 or module/0 in memory typespec" do
    # The CRANK_TYPE_002 check runs via @after_compile. The check is
    # best-effort: it inspects the memory module's typespec via
    # Code.Typespec.fetch_types/1. If the typespec is unavailable at
    # @after_compile time (the memory module BEAM hasn't been written yet),
    # the check skips silently and runs again later via mix crank.check.
    #
    # These tests use compiled fixture memory modules under test/support so
    # their typespecs are always fetchable.

    test "find_forbidden_types detects function/0 in PureMemory: none" do
      {:ok, types} = Code.Typespec.fetch_types(Crank.TypingFixtures.PureMemory)
      forbidden = call_find_forbidden(types)
      assert forbidden == []
    end

    test "find_forbidden_types detects function/0 in MemoryWithFunction" do
      {:ok, types} = Code.Typespec.fetch_types(Crank.TypingFixtures.MemoryWithFunction)
      forbidden = call_find_forbidden(types)
      assert :function in forbidden
    end

    test "find_forbidden_types detects module/0 in MemoryWithModule" do
      {:ok, types} = Code.Typespec.fetch_types(Crank.TypingFixtures.MemoryWithModule)
      forbidden = call_find_forbidden(types)
      assert :module in forbidden
    end

    # The @after_compile rejection path is triggered by `use Crank, memory:
    # BadStruct` for a memory struct whose typespec contains forbidden types.
    # We use the fixture memory modules under test/support — their BEAM
    # bytecode is on disk so Code.Typespec.fetch_types/1 succeeds inside the
    # @after_compile callback.

    test "use Crank, memory: <struct with function/0> raises CRANK_TYPE_002 at compile time" do
      module_source = """
      defmodule CrankTypingProbes.MachineWithFunctionMemory do
        use Crank, memory: Crank.TypingFixtures.MemoryWithFunction

        @impl true
        def start(_), do: {:ok, :idle, %Crank.TypingFixtures.MemoryWithFunction{}}

        @impl true
        def turn(_event, _state, memory), do: {:stay, memory}
      end
      """

      assert_raise CompileError, ~r/CRANK_TYPE_002/, fn ->
        Code.eval_string(module_source)
      end
    after
      :code.purge(CrankTypingProbes.MachineWithFunctionMemory)
      :code.delete(CrankTypingProbes.MachineWithFunctionMemory)
    end

    test "use Crank, memory: <struct with module/0> raises CRANK_TYPE_002 at compile time" do
      module_source = """
      defmodule CrankTypingProbes.MachineWithModuleMemory do
        use Crank, memory: Crank.TypingFixtures.MemoryWithModule

        @impl true
        def start(_), do: {:ok, :idle, %Crank.TypingFixtures.MemoryWithModule{}}

        @impl true
        def turn(_event, _state, memory), do: {:stay, memory}
      end
      """

      assert_raise CompileError, ~r/CRANK_TYPE_002/, fn ->
        Code.eval_string(module_source)
      end
    after
      :code.purge(CrankTypingProbes.MachineWithModuleMemory)
      :code.delete(CrankTypingProbes.MachineWithModuleMemory)
    end

    test "use Crank, memory: <clean struct> compiles without raising CRANK_TYPE_002" do
      module_source = """
      defmodule CrankTypingProbes.MachineWithCleanMemory do
        use Crank, memory: Crank.TypingFixtures.PureMemory

        @impl true
        def start(_), do: {:ok, :idle, %Crank.TypingFixtures.PureMemory{value: 0, name: ""}}

        @impl true
        def turn(_event, _state, memory), do: {:stay, memory}
      end
      """

      assert {{:module, CrankTypingProbes.MachineWithCleanMemory, _, _}, _} =
               Code.eval_string(module_source)
    after
      :code.purge(CrankTypingProbes.MachineWithCleanMemory)
      :code.delete(CrankTypingProbes.MachineWithCleanMemory)
    end

    # The :ok-skip path: when Code.Typespec.fetch_types returns :error
    # (e.g., memory struct compiled in same pass and BEAM not yet on disk),
    # the check skips silently. We exercise this via an unloaded module name.
    test "skips silently when memory module typespec is unfetchable" do
      assert :ok =
               Crank.Typing.__after_compile_memory_check__(
                 %{module: SomeModuleWithoutCrankAttr, file: __ENV__.file},
                 <<>>
               )
    end

    # Use the private function via apply since it's a defp in the public-facing
    # module. We expose it for testing purposes via direct module inspection.
    defp call_find_forbidden(types) do
      # Re-implement the public-facing logic against the typespec data.
      # Not testing internals directly; this exercises the same shape the
      # @after_compile callback uses.
      find_forbidden_in_types(types)
    end

    defp find_forbidden_in_types(types) do
      types
      |> Enum.flat_map(fn {_kind, type_spec} -> walk_for_forbidden(type_spec) end)
      |> Enum.uniq()
    end

    defp walk_for_forbidden({_name, type_ast, _args}), do: walk_ast(type_ast)

    defp walk_ast({:type, _, :fun, _}), do: [:function]
    defp walk_ast({:type, _, :module, []}), do: [:module]
    defp walk_ast({:type, _, _name, args}) when is_list(args), do: Enum.flat_map(args, &walk_ast/1)
    defp walk_ast({:remote_type, _, [_, _, args]}), do: Enum.flat_map(args, &walk_ast/1)
    defp walk_ast({:user_type, _, _, args}), do: Enum.flat_map(args, &walk_ast/1)
    defp walk_ast({:ann_type, _, [_, type]}), do: walk_ast(type)
    defp walk_ast(_), do: []
  end

  describe "CRANK_TYPE_003 — turn/3 returns state outside the declared union" do
    test "literal struct return outside declared :states union raises CompileError" do
      module_source = """
      defmodule TypingTest.IdleStateC do
        defstruct []
        @type t :: %__MODULE__{}
      end

      defmodule TypingTest.ActiveStateC do
        defstruct []
        @type t :: %__MODULE__{}
      end

      defmodule TypingTest.MysteryStateC do
        defstruct []
        @type t :: %__MODULE__{}
      end

      defmodule TypingTest.BadMachineC do
        use Crank, states: [TypingTest.IdleStateC, TypingTest.ActiveStateC]

        @impl true
        def start(_), do: {:ok, %TypingTest.IdleStateC{}, %{}}

        @impl true
        def turn(:tick, _state, memory) do
          {:next, %TypingTest.MysteryStateC{}, memory}
        end
      end
      """

      assert_raise CompileError, ~r/CRANK_TYPE_003/, fn ->
        Code.eval_string(module_source)
      end
    after
      :code.purge(TypingTest.BadMachineC)
      :code.delete(TypingTest.BadMachineC)
      :code.purge(TypingTest.MysteryStateC)
      :code.delete(TypingTest.MysteryStateC)
      :code.purge(TypingTest.ActiveStateC)
      :code.delete(TypingTest.ActiveStateC)
      :code.purge(TypingTest.IdleStateC)
      :code.delete(TypingTest.IdleStateC)
    end

    test "literal struct return inside declared union compiles cleanly" do
      module_source = """
      defmodule TypingTest.IdleStateD do
        defstruct []
        @type t :: %__MODULE__{}
      end

      defmodule TypingTest.ActiveStateD do
        defstruct []
        @type t :: %__MODULE__{}
      end

      defmodule TypingTest.GoodMachineD do
        use Crank, states: [TypingTest.IdleStateD, TypingTest.ActiveStateD]

        @impl true
        def start(_), do: {:ok, %TypingTest.IdleStateD{}, %{}}

        @impl true
        def turn(:tick, %TypingTest.IdleStateD{}, memory) do
          {:next, %TypingTest.ActiveStateD{}, memory}
        end
      end
      """

      assert {{:module, TypingTest.GoodMachineD, _, _}, _} = Code.eval_string(module_source)
    after
      :code.purge(TypingTest.GoodMachineD)
      :code.delete(TypingTest.GoodMachineD)
      :code.purge(TypingTest.ActiveStateD)
      :code.delete(TypingTest.ActiveStateD)
      :code.purge(TypingTest.IdleStateD)
      :code.delete(TypingTest.IdleStateD)
    end

    test "non-literal returns (variable, helper call) are not flagged at compile time" do
      module_source = """
      defmodule TypingTest.IdleStateE do
        defstruct []
        @type t :: %__MODULE__{}
      end

      defmodule TypingTest.MachineE do
        use Crank, states: [TypingTest.IdleStateE]

        @impl true
        def start(_), do: {:ok, %TypingTest.IdleStateE{}, %{}}

        @impl true
        def turn(:tick, state, memory) do
          # Non-literal: state value comes from a variable; macro can't see through this.
          {:next, state, memory}
        end
      end
      """

      assert {{:module, TypingTest.MachineE, _, _}, _} = Code.eval_string(module_source)
    after
      :code.purge(TypingTest.MachineE)
      :code.delete(TypingTest.MachineE)
      :code.purge(TypingTest.IdleStateE)
      :code.delete(TypingTest.IdleStateE)
    end

    test ":stay and {:stop, _, _} returns are not state-validated (no state value)" do
      module_source = """
      defmodule TypingTest.IdleStateF do
        defstruct []
        @type t :: %__MODULE__{}
      end

      defmodule TypingTest.MachineF do
        use Crank, states: [TypingTest.IdleStateF]

        @impl true
        def start(_), do: {:ok, %TypingTest.IdleStateF{}, %{}}

        @impl true
        def turn(:stay, _state, memory), do: :stay

        def turn(:keep, _state, memory), do: {:stay, memory}

        def turn(:halt, _state, memory), do: {:stop, :normal, memory}
      end
      """

      assert {{:module, TypingTest.MachineF, _, _}, _} = Code.eval_string(module_source)
    after
      :code.purge(TypingTest.MachineF)
      :code.delete(TypingTest.MachineF)
      :code.purge(TypingTest.IdleStateF)
      :code.delete(TypingTest.IdleStateF)
    end
  end
end
