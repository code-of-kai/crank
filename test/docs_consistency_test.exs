defmodule Crank.DocsConsistencyTest do
  @moduledoc """
  Regression tests that pin remediation snippets in shipped docs
  against the rules `mix crank.check` actually enforces.

  Codex review #27 (2026-05-08) flagged that doc snippets had
  drifted away from runtime expectations: an old major-version
  pin and a compiler-order pattern that the new
  `validate_compiler_position/0` rejects. Without an automated
  consistency check, the same drift can recur every release.

  Each rule below scans the relevant docs and asserts the bad
  pattern doesn't appear and the canonical good pattern does.
  """
  use ExUnit.Case, async: true

  @doc_paths [
    "README.md",
    "CHANGELOG.md",
    "guides/boundary-setup.md",
    "guides/violations/CRANK_SETUP_001.md"
  ]

  describe "compiler-order pattern" do
    # `Mix.compilers() ++ [:crank]` (append) is rejected by
    # `Mix.Tasks.Crank.Check.validate_compiler_position/0`. Code
    # snippets prescribing it would lead users into a setup the
    # gate explicitly fails. Mentions inside cautionary prose
    # (warning users away from the pattern) are allowed by
    # convention: the bad pattern must be inside backticks AND
    # not preceded by "never " or "not " on the same line, AND
    # not appear in a code-block context where it's being shown
    # as the WRONG example.
    test "no doc prescribes Mix.compilers() ++ [:crank] outside a 'don't do this' context" do
      bad = "Mix.compilers() ++ [:crank]"

      offenders =
        for path <- @doc_paths,
            File.exists?(path),
            line <- File.read!(path) |> String.split("\n"),
            String.contains?(line, bad),
            not warning_context?(line),
            do: {path, line}

      assert offenders == [],
             "doc snippets prescribe append-style compiler order:\n" <>
               Enum.map_join(offenders, "\n", fn {p, l} -> "  #{p}: #{String.trim(l)}" end)
    end
  end

  describe "dep version" do
    # The published major is 2.x. Pre-v2 snippets (`~> 1.x` or
    # `~> 1.0`) would lock users into the wrong release surface.
    test "no doc snippet pins :crank to a pre-v2 major" do
      bad_pattern = ~r/\{:crank,\s*"~>\s*1\./

      offenders =
        for path <- @doc_paths,
            File.exists?(path),
            match = Regex.scan(bad_pattern, File.read!(path)),
            match != [],
            do: {path, match}

      assert offenders == [],
             "doc snippets pin :crank to a pre-v2 major:\n" <>
               Enum.map_join(offenders, "\n", fn {p, m} -> "  #{p}: #{inspect(m)}" end)
    end
  end

  # A line "warns about" the bad pattern if it includes a negation
  # word adjacent to the pattern reference. Crude but catches the
  # warnings we deliberately ship (e.g. "never `Mix.compilers() ++
  # [:crank]`").
  defp warning_context?(line) do
    Regex.match?(~r/\b(never|not|don'?t|avoid|reject|wrong|rejected)\b/i, line)
  end
end
