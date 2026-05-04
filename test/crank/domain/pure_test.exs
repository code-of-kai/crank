defmodule Crank.Domain.PureTest do
  use ExUnit.Case, async: true

  describe "use Crank.Domain.Pure" do
    test "tags the module with a Boundary persisted attribute (type :strict)" do
      Code.eval_string("""
      defmodule Crank.Domain.PureTest.SimpleHelper do
        use Crank.Domain.Pure

        def double(x), do: x * 2
      end
      """)

      assert %{opts: opts} = boundary_attribute(Crank.Domain.PureTest.SimpleHelper)
      assert Keyword.get(opts, :type) == :strict
      # `Crank` is auto-added so macro-injected references (Crank.Server,
      # Crank.Check.CompileTime) don't trip Boundary's strict-mode external-dep check.
      assert Keyword.get(opts, :deps) == [Crank]
      assert Keyword.get(opts, :exports) == []
    after
      :code.purge(Crank.Domain.PureTest.SimpleHelper)
      :code.delete(Crank.Domain.PureTest.SimpleHelper)
    end

    test "passes :boundary_deps through to the Boundary attribute" do
      Code.eval_string("""
      defmodule Crank.Domain.PureTest.WithDeps do
        use Crank.Domain.Pure, boundary_deps: [Crank]

        def hello, do: :ok
      end
      """)

      assert %{opts: opts} = boundary_attribute(Crank.Domain.PureTest.WithDeps)
      assert Crank in Keyword.get(opts, :deps)
    after
      :code.purge(Crank.Domain.PureTest.WithDeps)
      :code.delete(Crank.Domain.PureTest.WithDeps)
    end

    test "applies the Crank.Check.CompileTime AST blacklist to every function body" do
      module_source = """
      defmodule Crank.Domain.PureTest.ImpureHelper do
        use Crank.Domain.Pure

        def now, do: DateTime.utc_now()
      end
      """

      assert_raise CompileError, ~r/CRANK_PURITY_004/, fn ->
        Code.eval_string(module_source)
      end
    end

    test "private functions are also walked by the AST blacklist" do
      module_source = """
      defmodule Crank.Domain.PureTest.ImpurePrivateHelper do
        use Crank.Domain.Pure

        def compute(x), do: with_log(x)
        defp with_log(x) do
          _ = Logger.info("computing")
          x
        end
      end
      """

      assert_raise CompileError, ~r/CRANK_PURITY_003/, fn ->
        Code.eval_string(module_source)
      end
    end

    test "pure helper module compiles cleanly" do
      Code.eval_string("""
      defmodule Crank.Domain.PureTest.CleanHelper do
        use Crank.Domain.Pure

        def with_tax(amount, rate), do: amount * (1 + rate)
        def round_to(amount, places) do
          factor = :math.pow(10, places)
          Float.round(amount * factor) / factor
        end
      end
      """)

      assert function_exported?(Crank.Domain.PureTest.CleanHelper, :with_tax, 2)
    after
      :code.purge(Crank.Domain.PureTest.CleanHelper)
      :code.delete(Crank.Domain.PureTest.CleanHelper)
    end

    test "sets the @__crank_domain_pure__ marker attribute" do
      Code.eval_string("""
      defmodule Crank.Domain.PureTest.MarkerProbe do
        use Crank.Domain.Pure

        def add(a, b), do: a + b

        @marker_probe Module.get_attribute(__MODULE__, :__crank_domain_pure__)
        def marker, do: @marker_probe
      end
      """)

      assert Crank.Domain.PureTest.MarkerProbe.marker() == true
    after
      :code.purge(Crank.Domain.PureTest.MarkerProbe)
      :code.delete(Crank.Domain.PureTest.MarkerProbe)
    end

    test "build_boundary_opts/1 builds the expected options (Crank auto-added to deps)" do
      assert [type: :strict, deps: [Crank], exports: []] = Crank.Domain.Pure.build_boundary_opts([])

      assert [type: :strict, deps: [Crank, Foo], exports: [Bar]] =
               Crank.Domain.Pure.build_boundary_opts(boundary_deps: [Foo], boundary_exports: [Bar])

      assert [type: :relaxed, deps: [Crank], exports: []] =
               Crank.Domain.Pure.build_boundary_opts(type: :relaxed)

      # Crank is not duplicated when the user explicitly lists it
      assert [type: :strict, deps: [Crank], exports: []] =
               Crank.Domain.Pure.build_boundary_opts(boundary_deps: [Crank])
    end
  end

  describe "use Crank emits the same Boundary tag" do
    test "Crank.Examples.Door has a Boundary persisted attribute" do
      assert %{opts: opts} = boundary_attribute(Crank.Examples.Door)
      assert Keyword.get(opts, :type) == :strict
      assert Keyword.get(opts, :deps) == [Crank]
    end

    test "Crank.Examples.VendingMachine has a Boundary persisted attribute" do
      assert %{opts: opts} = boundary_attribute(Crank.Examples.VendingMachine)
      assert Keyword.get(opts, :type) == :strict
    end
  end

  defp boundary_attribute(module) do
    case Keyword.get(module.__info__(:attributes), Boundary) do
      [data] when is_map(data) -> data
      _ -> nil
    end
  end
end
