defmodule Crank.Domain.PureTest do
  use ExUnit.Case, async: true

  alias Crank.Domain.Pure

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
      probe = Crank.Domain.PureTest.MarkerProbe

      Code.eval_string("""
      defmodule #{inspect(probe)} do
        use Crank.Domain.Pure

        def add(a, b), do: a + b

        @marker_probe Module.get_attribute(__MODULE__, :__crank_domain_pure__)
        def marker, do: @marker_probe
      end
      """)

      assert probe.marker() == true
    after
      :code.purge(Crank.Domain.PureTest.MarkerProbe)
      :code.delete(Crank.Domain.PureTest.MarkerProbe)
    end

    test "build_boundary_opts/1 builds the expected options (Crank auto-added to deps)" do
      assert [type: :strict, deps: [Crank], exports: []] = Pure.build_boundary_opts([])

      assert [type: :strict, deps: [Crank, Foo], exports: [Bar]] =
               Pure.build_boundary_opts(boundary_deps: [Foo], boundary_exports: [Bar])

      assert [type: :relaxed, deps: [Crank], exports: []] =
               Pure.build_boundary_opts(type: :relaxed)

      # Crank is not duplicated when the user explicitly lists it
      assert [type: :strict, deps: [Crank], exports: []] =
               Pure.build_boundary_opts(boundary_deps: [Crank])
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

  describe "__crank_domain__ marker — tamper-resistant" do
    # Codex review #3 (2026-05-06) flagged that a non-accumulating
    # marker could be downgraded by `@__crank_domain__ false` after
    # `use Crank`. The attribute is now registered with
    # `accumulate: true, persist: true`, so a later `false` value
    # adds to the list rather than replacing the `true` we set.
    # The Mix-task detection asks "is `true` anywhere in the
    # accumulated list?", which makes the tag write-once.

    test "use Crank produces an accumulated list with at least one `true`" do
      values = crank_domain_values(Crank.Examples.Door)

      assert true in values,
             "expected `true` in accumulated :__crank_domain__ list, got: #{inspect(values)}"
    end

    test "use Crank.Domain.Pure also accumulates a `true`" do
      Code.eval_string("""
      defmodule Crank.Domain.PureTest.MarkerTamperResistance do
        use Crank.Domain.Pure

        def add(a, b), do: a + b
      end
      """)

      values = crank_domain_values(Crank.Domain.PureTest.MarkerTamperResistance)
      assert true in values
    after
      :code.purge(Crank.Domain.PureTest.MarkerTamperResistance)
      :code.delete(Crank.Domain.PureTest.MarkerTamperResistance)
    end

    test "user appending `@__crank_domain__ false` does NOT remove the original `true`" do
      Code.eval_string("""
      defmodule Crank.Domain.PureTest.AttemptedTamper do
        use Crank

        # Simulate the threat model: a user (or a clumsy macro) writes
        # `false` after `use Crank`, hoping to opt out of CRANK_DEP_002
        # detection without removing the `use` line. With the
        # accumulating marker, this is a no-op for the detection logic.
        @__crank_domain__ false

        @impl true
        def start(_), do: {:ok, :idle, %{}}

        @impl true
        def turn(_event, :idle, memory), do: {:next, :active, memory}

        @impl true
        def turn(_event, :active, memory), do: {:stay, memory}
      end
      """)

      values = crank_domain_values(Crank.Domain.PureTest.AttemptedTamper)

      assert true in values, "tamper attempt should not remove the `true` value"
      assert false in values, "the `false` is still recorded (visible to reviewers/auditors)"
    after
      :code.purge(Crank.Domain.PureTest.AttemptedTamper)
      :code.delete(Crank.Domain.PureTest.AttemptedTamper)
    end
  end

  defp boundary_attribute(module) do
    case Keyword.get(module.__info__(:attributes), Boundary) do
      [data] when is_map(data) -> data
      _ -> nil
    end
  end

  defp crank_domain_values(module) do
    module.__info__(:attributes)
    |> Keyword.get_values(:__crank_domain__)
    |> List.flatten()
  end
end
