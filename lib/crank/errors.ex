defmodule Crank.Errors do
  @moduledoc """
  Single source of truth for rendering Crank purity-enforcement violations.

  Every check (Credo, `@before_compile`, Boundary integration,
  `Crank.PurityTrace`, property tests) constructs a `Crank.Errors.Violation`
  and funnels through this module to produce the format their surrounding
  context expects: a `CompileError`, a Credo issue, a property-test failure,
  or a structured map for agent consumption.

  Suppression is **not** owned by this module — see `Crank.Suppressions`
  (Layer A, source-adjacent comments) and the integration-specific suppression
  mechanisms for Layer B (Boundary config) and Layer C (programmatic `:allow`
  opts on test helpers).
  """

  alias Crank.Errors.Catalog
  alias Crank.Errors.Violation

  # ── Pretty-printed form (humans, terminal, IDE) ─────────────────────────────

  @doc """
  Renders a `%Violation{}` as a human-readable terminal-friendly string.

  The pretty form contains five sections:

    1. Header: `error: [CODE] short description`
    2. Location: `path:line:column` (column omitted if absent)
    3. Why: one paragraph from the catalog's short description
    4. Fix: the canonical fix category and (when present) before/after snippets
    5. See: hexdocs URL for the per-code documentation page
  """
  @spec format_pretty(Violation.t()) :: String.t()
  def format_pretty(%Violation{} = v) do
    [
      header_line(v),
      location_line(v),
      "",
      "  Why: #{v.fix.category}",
      v.context && "  Context: #{v.context}",
      "",
      fix_section(v),
      "",
      "  See: #{v.fix.doc_url}",
      ""
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp header_line(%Violation{code: code, severity: severity}) do
    label =
      case severity do
        :error -> "error"
        :warning -> "warning"
      end

    "#{label}: [#{code}] Crank purity-enforcement violation"
  end

  defp location_line(%Violation{location: %{file: file, line: line} = loc})
       when is_binary(file) and is_integer(line) do
    case Map.get(loc, :column) do
      nil -> "  #{file}:#{line}"
      col when is_integer(col) -> "  #{file}:#{line}:#{col}"
    end
  end

  defp location_line(_), do: "  (location unavailable)"

  defp fix_section(%Violation{fix: fix}) do
    body =
      [
        fix[:before] && ["  Wrong:", indent(fix.before, 4)],
        fix[:after] && ["  Right:", indent(fix.after, 4)],
        fix[:setup] && ["  Setup (one-time):", indent(fix.setup, 4)]
      ]
      |> Enum.reject(&is_nil/1)
      |> List.flatten()

    case body do
      [] -> "  Fix: #{fix.category}"
      lines -> Enum.join(["  Fix: #{fix.category}" | lines], "\n")
    end
  end

  defp indent(text, n) do
    pad = String.duplicate(" ", n)

    text
    |> String.split("\n")
    |> Enum.map_join("\n", &(pad <> &1))
  end

  # ── Structured form (JSON, agent consumption) ──────────────────────────────

  @doc """
  Renders a `%Violation{}` as a JSON-serialisable map.

  Stable schema; field names and shapes are part of Crank's API contract.
  Coding agents and external tools consume this form via `--format=json`
  on `mix crank.check`.
  """
  @spec format_structured(Violation.t()) :: map()
  def format_structured(%Violation{} = v) do
    %{
      "code" => v.code,
      "severity" => Atom.to_string(v.severity),
      "rule" => Atom.to_string(v.rule),
      "location" => format_location(v.location),
      "violating_call" => format_call(v.violating_call),
      "context" => v.context,
      "fix" => format_fix(v.fix),
      "metadata" => v.metadata
    }
  end

  defp format_location(loc) when is_map(loc) do
    %{
      "file" => to_nilable_string(loc[:file]),
      "line" => loc[:line],
      "column" => loc[:column],
      "function" => loc[:function]
    }
  end

  defp format_call(nil), do: nil

  defp format_call(call) when is_map(call) do
    %{
      "module" => format_module(call[:module]),
      "function" => to_nilable_string(call[:function]),
      "arity" => call[:arity]
    }
  end

  defp format_module(nil), do: nil
  defp format_module(value) when is_binary(value), do: value

  defp format_module(value) when is_atom(value) do
    case Atom.to_string(value) do
      "Elixir." <> rest -> rest
      other -> other
    end
  end

  defp format_fix(fix) when is_map(fix) do
    %{
      "category" => fix.category,
      "before" => fix[:before],
      "after" => fix[:after],
      "setup" => fix[:setup],
      "doc_url" => fix.doc_url
    }
  end

  defp to_nilable_string(nil), do: nil
  defp to_nilable_string(value) when is_binary(value), do: value
  defp to_nilable_string(value), do: to_string(value)

  # ── Sink-specific renderers ────────────────────────────────────────────────

  @doc """
  Renders a `%Violation{}` as a `CompileError`. Used by the `@before_compile`
  hook (1.3) and by `Crank.Compiler` (1.4) when raising at compile time.
  """
  @spec to_compile_error(Violation.t()) :: Exception.t()
  def to_compile_error(%Violation{} = v) do
    file = (v.location && v.location[:file]) || "(unknown)"
    line = (v.location && v.location[:line]) || 0

    %CompileError{
      file: file,
      line: line,
      description: format_pretty(v)
    }
  end

  @doc """
  Renders a `%Violation{}` as an `ExUnit.AssertionError`. Used by
  `Crank.PropertyTest` (2.3) when a property test detects a violation.
  """
  @spec to_property_test_failure(Violation.t()) :: ExUnit.AssertionError.t()
  def to_property_test_failure(%Violation{} = v) do
    %ExUnit.AssertionError{
      message: format_pretty(v),
      expr: nil,
      args: nil
    }
  end

  @doc """
  Builds a `%Violation{}` from a catalog code with optional overrides.

  This is the canonical constructor for checks that have already determined
  the catalog code; it pulls in the catalog's `short`, `severity`, `rule`,
  and `doc_url` automatically.
  """
  @spec build(binary(), keyword()) :: Violation.t()
  def build(code, opts \\ []) when is_binary(code) do
    entry = Catalog.fetch!(code)

    %Violation{
      code: code,
      severity: Keyword.get(opts, :severity, entry.severity),
      rule: Keyword.get(opts, :rule, entry.rule),
      location: Keyword.get(opts, :location, %{file: nil, line: nil}),
      violating_call: Keyword.get(opts, :violating_call),
      context: Keyword.get(opts, :context),
      fix: build_fix(entry, opts),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp build_fix(entry, opts) do
    %{
      category: Keyword.get(opts, :fix_category, entry.fix_category),
      before: Keyword.get(opts, :fix_before),
      after: Keyword.get(opts, :fix_after),
      setup: Keyword.get(opts, :fix_setup),
      doc_url: entry.doc_url
    }
  end
end
