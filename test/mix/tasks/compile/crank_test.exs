defmodule Mix.Tasks.Compile.CrankTest do
  use ExUnit.Case, async: true

  describe "Mix.Tasks.Compile.Crank" do
    test "implements Mix.Task.Compiler with @recursive true" do
      assert Mix.Tasks.Compile.Crank.__info__(:attributes)
             |> Keyword.get(:recursive) == [true]

      assert function_exported?(Mix.Tasks.Compile.Crank, :run, 1)
    end

    test "module exports Mix.Task.Compiler behaviour callbacks" do
      behaviours =
        Mix.Tasks.Compile.Crank.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Mix.Task.Compiler in behaviours
    end
  end
end
