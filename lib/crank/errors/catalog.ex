defmodule Crank.Errors.Catalog do
  @moduledoc """
  Frozen registry of every Crank purity-enforcement violation code.

  Codes are stable across major versions. Adding new codes is non-breaking;
  renaming or removing requires a major version bump and migration notes.
  The catalog test in `test/crank/errors/catalog_test.exs` enforces:

    * every code in this module has a fix template
    * every code has a doc page under `guides/violations/`
    * every code is referenced by at least one check
    * every code referenced in source is present here

  See `plans/purity-enforcement.md` for the per-code ownership table that
  maps each code to its detection mechanism, owning component, and test
  fixture.
  """

  @typedoc "Catalog entry for a single violation code."
  @type entry :: %{
          required(:code) => binary(),
          required(:rule) => atom(),
          required(:severity) => :error | :warning,
          required(:layer) => :static_call_site | :static_topology | :runtime | :type | :meta | :setup,
          required(:short) => binary(),
          required(:doc_url) => binary(),
          required(:fix_category) => binary()
        }

  @doc_url_base "https://hexdocs.pm/crank/"

  @entries [
    # ── Phase 1.1 / 1.3 — call-site purity violations ───────────────────────
    %{
      code: "CRANK_PURITY_001",
      rule: :turn_purity_direct,
      severity: :error,
      layer: :static_call_site,
      short: "Direct impure call inside `turn/3` body.",
      fix_category: "telemetry-as-want or wants/2 declaration"
    },
    %{
      code: "CRANK_PURITY_002",
      rule: :turn_purity_discarded,
      severity: :error,
      layer: :static_call_site,
      short: "Discarded return value (`_ = some_call()`) inside `turn/3`.",
      fix_category: "remove the call or move it to wants/2"
    },
    %{
      code: "CRANK_PURITY_003",
      rule: :turn_purity_logger,
      severity: :error,
      layer: :static_call_site,
      short: "`Logger.*` call inside `turn/3` body.",
      fix_category: "telemetry-as-want; attach logging adapter at boundary"
    },
    %{
      code: "CRANK_PURITY_004",
      rule: :turn_purity_nondeterminism,
      severity: :error,
      layer: :static_call_site,
      short: "Time or randomness call inside `turn/3` (sample at boundary).",
      fix_category: "pass the value in via the event payload"
    },
    %{
      code: "CRANK_PURITY_005",
      rule: :turn_purity_process_comm,
      severity: :error,
      layer: :static_call_site,
      short: "`send/2`, `Task`, `spawn`, or `GenServer` call inside `turn/3`.",
      fix_category: "wants/2 with `{:send, dest, message}` or telemetry-as-want"
    },
    %{
      code: "CRANK_PURITY_006",
      rule: :turn_purity_ambient_state,
      severity: :error,
      layer: :static_call_site,
      short: "ETS, persistent_term, or process dictionary access inside `turn/3`.",
      fix_category: "load values into memory at machine start; carry them through"
    },
    %{
      code: "CRANK_PURITY_007",
      rule: :turn_purity_transitive,
      severity: :error,
      layer: :runtime,
      short: "Runtime trace observed impure call via helper (transitive impurity).",
      fix_category: "remove the impurity from the helper or move it behind a Crank.Domain.Pure marker"
    },

    # ── Phase 1.4 — topology violations (Boundary) ──────────────────────────
    %{
      code: "CRANK_DEP_001",
      rule: :dependency_direction,
      severity: :error,
      layer: :static_topology,
      short: "Domain module references infrastructure module.",
      fix_category: "move the call into an adapter; receive the result via event"
    },
    %{
      code: "CRANK_DEP_002",
      rule: :unmarked_domain_helper,
      severity: :error,
      layer: :static_topology,
      short: "Domain module calls unmarked first-party helper (strict mode).",
      fix_category: "mark the helper with `use Crank.Domain.Pure`"
    },
    %{
      code: "CRANK_DEP_003",
      rule: :unclassified_external_dep,
      severity: :error,
      layer: :static_topology,
      short: "Domain module calls a third-party app not classified in Boundary config.",
      fix_category: "add the app to `:third_party_pure` or `:third_party_impure`"
    },

    # ── Phase 1.6 / 1.7 — type-level violations ─────────────────────────────
    %{
      code: "CRANK_TYPE_001",
      rule: :memory_field_unknown,
      severity: :error,
      layer: :type,
      short: "Struct-update or struct-literal references a field not declared in the memory struct.",
      fix_category: "add the field to defstruct, or remove the reference"
    },
    %{
      code: "CRANK_TYPE_002",
      rule: :function_in_memory,
      severity: :error,
      layer: :type,
      short: "Module or function value declared in memory or state typespec.",
      fix_category: "carry data, not behavior; pass module names via events instead"
    },
    %{
      code: "CRANK_TYPE_003",
      rule: :unknown_state_returned,
      severity: :warning,
      layer: :type,
      short: "`turn/3` returns a state not in the declared state union.",
      fix_category: "add the state to the declared union, or change the return"
    },

    # ── Phase 2.1 / 2.2 — runtime violations ────────────────────────────────
    %{
      code: "CRANK_RUNTIME_001",
      rule: :resource_heap,
      severity: :error,
      layer: :runtime,
      short: "Heap exhaustion observed during traced turn.",
      fix_category: "raise `max_heap_size`, or fix the unbounded allocation in `turn/3`"
    },
    %{
      code: "CRANK_RUNTIME_002",
      rule: :resource_timeout,
      severity: :error,
      layer: :runtime,
      short: "Turn exceeded timeout.",
      fix_category: "raise `turn_timeout`, or fix the non-terminating logic in `turn/3`"
    },

    # ── Phase 2.1 — runtime trace mutations ─────────────────────────────────
    %{
      code: "CRANK_TRACE_001",
      rule: :atom_table_mutation,
      severity: :warning,
      layer: :runtime,
      short: "New atom created during turn (atom-table mutation).",
      fix_category: "use `String.to_existing_atom/1` or carry the atom in via event"
    },
    %{
      code: "CRANK_TRACE_002",
      rule: :process_dict_mutation,
      severity: :error,
      layer: :runtime,
      short: "Process dictionary modified during turn.",
      fix_category: "carry the value in memory; never write to the process dict"
    },

    # ── Phase 3.4 — suppression-mechanism violations ────────────────────────
    %{
      code: "CRANK_META_001",
      rule: :suppression_missing_reason,
      severity: :error,
      layer: :meta,
      short: "`# crank-allow:` annotation without `# reason:` follow-up.",
      fix_category: "add `# reason: <plain-language explanation>` on the next line"
    },
    %{
      code: "CRANK_META_002",
      rule: :suppression_unknown_code,
      severity: :error,
      layer: :meta,
      short: "`# crank-allow:` references a code not in the catalog.",
      fix_category: "use a code from the frozen catalog; check spelling"
    },
    %{
      code: "CRANK_META_003",
      rule: :suppression_orphaned,
      severity: :error,
      layer: :meta,
      short: "`# crank-allow:` annotation with no following code line within 3 lines.",
      fix_category: "place the suppression directly above the offending code"
    },
    %{
      code: "CRANK_META_004",
      rule: :suppression_wrong_layer,
      severity: :error,
      layer: :meta,
      short: "`# crank-allow:` references a code that this layer cannot suppress.",
      fix_category: "use the correct suppression mechanism for this layer (Boundary config or `:allow` opt)"
    },

    # ── Phase 4.6 / 4.7 — setup violations ──────────────────────────────────
    %{
      code: "CRANK_SETUP_001",
      rule: :boundary_not_wired,
      severity: :error,
      layer: :setup,
      short: "Project lacks `:crank` in `:compilers`. Run `mix crank.gen.config`.",
      fix_category: "add `:crank` to `compilers:` in mix.exs"
    },
    %{
      code: "CRANK_SETUP_002",
      rule: :otp_version_too_old,
      severity: :error,
      layer: :setup,
      short: "Runtime OTP < 26; `Crank.PurityTrace` requires trace sessions (OTP 26+).",
      fix_category: "upgrade Erlang/OTP to 26 or later"
    }
  ]

  @all_entries Enum.map(@entries, fn entry ->
                 Map.put(entry, :doc_url, @doc_url_base <> entry.code <> ".html")
               end)
  @code_set @all_entries |> Enum.map(& &1.code) |> MapSet.new()
  @rule_set @all_entries |> Enum.map(& &1.rule) |> MapSet.new()

  @doc "Returns every catalog entry as a map."
  @spec all() :: [entry()]
  def all, do: @all_entries

  @doc "Returns every frozen code as a `MapSet`."
  @spec codes() :: MapSet.t(binary())
  def codes, do: @code_set

  @doc "Returns every rule atom as a `MapSet`."
  @spec rules() :: MapSet.t(atom())
  def rules, do: @rule_set

  @doc "Looks up a catalog entry by code. Returns `:error` if absent."
  @spec fetch(binary()) :: {:ok, entry()} | :error
  def fetch(code) when is_binary(code) do
    case Enum.find(@all_entries, &(&1.code == code)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @doc "Looks up a catalog entry by code; raises if absent."
  @spec fetch!(binary()) :: entry()
  def fetch!(code) when is_binary(code) do
    case fetch(code) do
      {:ok, entry} -> entry
      :error -> raise ArgumentError, "unknown Crank violation code: #{inspect(code)}"
    end
  end

  @doc """
  Returns codes whose layer can be suppressed by the given suppression mechanism.

  Layer A (source-adjacent comments) suppresses `:static_call_site`, `:type`, and
  some `:meta` codes. It cannot suppress `:static_topology` (Boundary config) or
  `:runtime` (programmatic `:allow` opt) — attempts raise `CRANK_META_004`.
  """
  @spec suppressible_by(:layer_a | :layer_b | :layer_c) :: [binary()]
  def suppressible_by(:layer_a),
    do: codes_for_layers([:static_call_site, :type, :meta])

  def suppressible_by(:layer_b),
    do: codes_for_layers([:static_topology])

  def suppressible_by(:layer_c),
    do: codes_for_layers([:runtime])

  defp codes_for_layers(layers) do
    layers_set = MapSet.new(layers)

    @all_entries
    |> Enum.filter(&MapSet.member?(layers_set, &1.layer))
    |> Enum.map(& &1.code)
  end
end
