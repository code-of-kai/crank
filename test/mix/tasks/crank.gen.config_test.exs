defmodule Mix.Tasks.Crank.Gen.ConfigTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Crank.Gen.Config

  # ── mix.exs transformations ────────────────────────────────────────────────

  describe "update_mix_exs_source/1 — fresh project" do
    @fresh_mix_exs ~S"""
    defmodule Foo.MixProject do
      use Mix.Project

      def project do
        [
          app: :foo,
          version: "0.1.0",
          elixir: "~> 1.15",
          deps: deps()
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end

      defp deps do
        [
          {:telemetry, "~> 1.0"}
        ]
      end
    end
    """

    test "adds :boundary and :crank to deps" do
      {new_source, changes} = Config.update_mix_exs_source(@fresh_mix_exs)

      assert String.contains?(new_source, ~s|{:boundary, "~> 0.10"}|)
      assert String.contains?(new_source, ~s|{:crank, "~> 1.2"}|)
      assert Enum.any?(changes, &String.contains?(&1, ":boundary"))
      assert Enum.any?(changes, &String.contains?(&1, ":crank"))
    end

    test "adds :crank to compilers list" do
      {new_source, changes} = Config.update_mix_exs_source(@fresh_mix_exs)

      assert String.contains?(new_source, "compilers: [:crank | Mix.compilers()]")
      assert Enum.any?(changes, &String.contains?(&1, ":compilers"))
    end

    test "adds :boundary classification keyword" do
      {new_source, changes} = Config.update_mix_exs_source(@fresh_mix_exs)

      assert String.contains?(new_source, "boundary: [third_party_pure: [], third_party_impure: []]")
      assert Enum.any?(changes, &String.contains?(&1, ":boundary classification"))
    end

    test "result still parses as valid Elixir" do
      {new_source, _} = Config.update_mix_exs_source(@fresh_mix_exs)
      assert {:ok, _ast} = Code.string_to_quoted(new_source)
    end
  end

  describe "update_mix_exs_source/1 — already-configured project" do
    @configured_mix_exs ~S"""
    defmodule Foo.MixProject do
      use Mix.Project

      def project do
        [
          app: :foo,
          version: "0.1.0",
          elixir: "~> 1.15",
          deps: deps(),
          compilers: [:crank | Mix.compilers()],
          boundary: [third_party_pure: [], third_party_impure: []]
        ]
      end

      defp deps do
        [
          {:telemetry, "~> 1.0"},
          {:boundary, "~> 0.10"},
          {:crank, "~> 1.2"}
        ]
      end
    end
    """

    test "produces no changes (idempotent)" do
      {new_source, changes} = Config.update_mix_exs_source(@configured_mix_exs)

      assert new_source == @configured_mix_exs
      assert changes == []
    end
  end

  describe "update_mix_exs_source/1 — partial config (existing :compilers)" do
    @partial_mix_exs ~S"""
    defmodule Foo.MixProject do
      use Mix.Project

      def project do
        [
          app: :foo,
          version: "0.1.0",
          elixir: "~> 1.15",
          deps: deps(),
          compilers: [:gettext | Mix.compilers()]
        ]
      end

      defp deps do
        [
          {:telemetry, "~> 1.0"}
        ]
      end
    end
    """

    test "merges :crank into existing :compilers list without clobbering" do
      {new_source, _changes} = Config.update_mix_exs_source(@partial_mix_exs)

      assert String.contains?(new_source, "compilers: [:crank, :gettext | Mix.compilers()]")
      assert {:ok, _ast} = Code.string_to_quoted(new_source)
    end
  end

  # ── .credo.exs transformations ─────────────────────────────────────────────

  describe "update_credo_source/1 — credo file with no Crank wiring" do
    @vanilla_credo ~S"""
    %{
      configs: [
        %{
          name: "default",
          files: %{included: ["lib/"], excluded: []},
          plugins: [],
          requires: [],
          strict: false,
          parse_timeout: 5000,
          color: true,
          checks: %{
            enabled: [
              {Credo.Check.Readability.ModuleDoc, []}
            ],
            disabled: []
          }
        }
      ]
    }
    """

    test "wires Crank.Check.TurnPurity into enabled checks" do
      {new_source, change} = Config.update_credo_source(@vanilla_credo)

      assert String.contains?(new_source, "{Crank.Check.TurnPurity, []}")
      assert change != nil
    end

    test "wires the requires path so Credo can load the check at startup" do
      {new_source, _change} = Config.update_credo_source(@vanilla_credo)

      assert String.contains?(new_source, ~s|"lib/crank/check/turn_purity.ex"|)
    end

    test "result still parses as valid Elixir" do
      {new_source, _} = Config.update_credo_source(@vanilla_credo)
      assert {:ok, _ast} = Code.string_to_quoted(new_source)
    end
  end

  describe "update_credo_source/1 — already-wired credo file" do
    @already_wired ~S"""
    %{
      configs: [
        %{
          name: "default",
          files: %{included: ["lib/"], excluded: []},
          plugins: [],
          requires: ["lib/crank/check/turn_purity.ex"],
          strict: false,
          parse_timeout: 5000,
          color: true,
          checks: %{
            enabled: [
              {Crank.Check.TurnPurity, []}
            ],
            disabled: []
          }
        }
      ]
    }
    """

    test "produces no changes" do
      {new_source, change} = Config.update_credo_source(@already_wired)

      assert new_source == @already_wired
      assert change == nil
    end
  end

  # ── filesystem tests ───────────────────────────────────────────────────────

  describe "wire_mix_exs/2 — filesystem effects" do
    @tag :tmp_dir
    test "writes the file when changes apply", %{tmp_dir: tmp} do
      path = Path.join(tmp, "mix.exs")

      File.write!(path, ~S"""
      defmodule Foo.MixProject do
        use Mix.Project

        def project do
          [app: :foo, version: "0.1.0", elixir: "~> 1.15", deps: deps()]
        end

        defp deps, do: []
      end
      """)

      [action | _] = Config.wire_mix_exs([], path)
      assert match?({:updated, ^path, _changes}, action)

      content = File.read!(path)
      assert String.contains?(content, ":boundary")
      assert String.contains?(content, ":crank")
    end

    @tag :tmp_dir
    test "is a no-op when already configured", %{tmp_dir: tmp} do
      path = Path.join(tmp, "mix.exs")
      original = ~S"""
      defmodule Foo.MixProject do
        use Mix.Project

        def project do
          [
            app: :foo,
            version: "0.1.0",
            elixir: "~> 1.15",
            deps: deps(),
            compilers: [:crank | Mix.compilers()],
            boundary: [third_party_pure: [], third_party_impure: []]
          ]
        end

        defp deps, do: [{:boundary, "~> 0.10"}, {:crank, "~> 1.2"}]
      end
      """

      File.write!(path, original)

      [action | _] = Config.wire_mix_exs([], path)
      assert {:noop, ^path, _} = action
      assert File.read!(path) == original
    end
  end

  describe "write_boundary_exs/2" do
    @tag :tmp_dir
    test "creates boundary.exs from the priv template", %{tmp_dir: tmp} do
      path = Path.join(tmp, "boundary.exs")

      [action | _] = Config.write_boundary_exs([], path)
      assert {:created, ^path, _} = action

      assert File.exists?(path)
      content = File.read!(path)
      assert String.contains?(content, "third_party_pure:")
      assert String.contains?(content, "third_party_impure:")
    end

    @tag :tmp_dir
    test "is a no-op when boundary.exs already exists", %{tmp_dir: tmp} do
      path = Path.join(tmp, "boundary.exs")
      File.write!(path, "[third_party_pure: [:decimal], third_party_impure: []]\n")

      [action | _] = Config.write_boundary_exs([], path)
      assert {:noop, ^path, _} = action

      assert File.read!(path) == "[third_party_pure: [:decimal], third_party_impure: []]\n"
    end
  end

  describe "wire_credo_exs/2" do
    @tag :tmp_dir
    test "creates a starter file when absent", %{tmp_dir: tmp} do
      path = Path.join(tmp, ".credo.exs")

      [action | _] = Config.wire_credo_exs([], path)
      assert {:created, ^path, _} = action
      assert File.exists?(path)

      content = File.read!(path)
      assert String.contains?(content, "Crank.Check.TurnPurity")
    end
  end
end
