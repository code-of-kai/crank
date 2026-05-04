defmodule Crank.Errors.ViolationFixturesTest do
  @moduledoc """
  Catalog consistency: every frozen code in `Crank.Errors.Catalog` has at
  least one fixture in `test/fixtures/violations/<CODE>.{exs,txt}` that
  documents how the code is triggered.

  `*.exs` fixtures are compile-time triggers — eval'ing them must raise
  a `CompileError` whose message names the code. `*.txt` fixtures are
  marker files for codes that can only be exercised at runtime, via
  Mix-task wiring, or via Boundary's compiler chain. The marker files
  contain the path to the test that actually verifies the trigger.
  """
  use ExUnit.Case, async: true

  alias Crank.Errors.Catalog

  @fixtures_dir Path.expand("../../fixtures/violations", __DIR__)

  setup_all do
    files = File.ls!(@fixtures_dir)
    {:ok, files: files}
  end

  describe "catalog coverage" do
    test "every catalog code has a fixture file", %{files: files} do
      missing =
        for entry <- Catalog.all(),
            not Enum.any?(files, &fixture_for?(&1, entry.code)),
            do: entry.code

      assert missing == [],
             "catalog codes without fixtures in test/fixtures/violations/: #{inspect(missing)}"
    end

    test "no orphan fixtures (every fixture matches a catalog code)", %{files: files} do
      catalog_codes = MapSet.new(Enum.map(Catalog.all(), & &1.code))

      orphans =
        files
        |> Enum.filter(&violation_fixture?/1)
        |> Enum.reject(&(file_to_code(&1) in catalog_codes))

      assert orphans == [],
             "fixture files without matching catalog codes: #{inspect(orphans)}"
    end
  end

  describe "compile-time fixtures (.exs)" do
    @compile_time_fixtures ~w(CRANK_PURITY_001 CRANK_PURITY_002 CRANK_PURITY_003
                              CRANK_PURITY_004 CRANK_PURITY_005 CRANK_PURITY_006)

    for code <- @compile_time_fixtures do
      test "#{code} fixture raises CompileError mentioning the code" do
        path = Path.join(@fixtures_dir, "#{unquote(code)}.exs")
        assert File.exists?(path), "expected fixture at #{path}"

        source = File.read!(path)

        assert_raise CompileError, ~r/#{unquote(code)}/, fn ->
          Code.eval_string(source)
        end
      end
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp fixture_for?(filename, code) do
    filename == "#{code}.exs" or filename == "#{code}.txt"
  end

  defp violation_fixture?(filename) do
    String.starts_with?(filename, "CRANK_") and
      (String.ends_with?(filename, ".exs") or String.ends_with?(filename, ".txt"))
  end

  defp file_to_code(filename) do
    filename
    |> String.replace_suffix(".exs", "")
    |> String.replace_suffix(".txt", "")
  end
end
