defmodule Crank.Errors.CatalogTest do
  use ExUnit.Case, async: true

  alias Crank.Errors.Catalog

  describe "all/0" do
    test "returns at least 22 codes (the v1 frozen catalog size)" do
      assert length(Catalog.all()) >= 22
    end

    test "every entry has the required keys" do
      for entry <- Catalog.all() do
        assert is_binary(entry.code)
        assert String.starts_with?(entry.code, "CRANK_")
        assert is_atom(entry.rule)
        assert entry.severity in [:error, :warning]
        assert entry.layer in [:static_call_site, :static_topology, :runtime, :type, :meta, :setup]
        assert is_binary(entry.short)
        assert is_binary(entry.fix_category)
        assert String.starts_with?(entry.doc_url, "https://hexdocs.pm/crank/")
      end
    end

    test "every code is unique" do
      codes = Enum.map(Catalog.all(), & &1.code)
      assert codes == Enum.uniq(codes)
    end

    test "every rule is unique" do
      rules = Enum.map(Catalog.all(), & &1.rule)
      assert rules == Enum.uniq(rules)
    end
  end

  describe "fetch/1" do
    test "returns {:ok, entry} for a known code" do
      assert {:ok, entry} = Catalog.fetch("CRANK_PURITY_001")
      assert entry.code == "CRANK_PURITY_001"
      assert entry.rule == :turn_purity_direct
    end

    test "returns :error for unknown codes" do
      assert :error = Catalog.fetch("CRANK_UNKNOWN_999")
    end
  end

  describe "fetch!/1" do
    test "raises on unknown code" do
      assert_raise ArgumentError, ~r/unknown Crank violation code/, fn ->
        Catalog.fetch!("CRANK_NOPE_000")
      end
    end
  end

  describe "suppressible_by/1" do
    test "Layer A covers static_call_site, type, and meta codes" do
      codes = Catalog.suppressible_by(:layer_a)
      assert "CRANK_PURITY_001" in codes
      assert "CRANK_TYPE_001" in codes
      assert "CRANK_META_001" in codes
      refute "CRANK_DEP_001" in codes
      refute "CRANK_PURITY_007" in codes
    end

    test "Layer B covers static_topology only" do
      codes = Catalog.suppressible_by(:layer_b)
      assert "CRANK_DEP_001" in codes
      assert "CRANK_DEP_002" in codes
      assert "CRANK_DEP_003" in codes
      refute "CRANK_PURITY_001" in codes
    end

    test "Layer C covers runtime only" do
      codes = Catalog.suppressible_by(:layer_c)
      assert "CRANK_PURITY_007" in codes
      assert "CRANK_RUNTIME_001" in codes
      assert "CRANK_RUNTIME_002" in codes
      assert "CRANK_TRACE_001" in codes
      refute "CRANK_PURITY_001" in codes
    end
  end

  describe "frozen v1 catalog" do
    @v1_codes ~w(
      CRANK_PURITY_001 CRANK_PURITY_002 CRANK_PURITY_003
      CRANK_PURITY_004 CRANK_PURITY_005 CRANK_PURITY_006 CRANK_PURITY_007
      CRANK_DEP_001 CRANK_DEP_002 CRANK_DEP_003
      CRANK_TYPE_001 CRANK_TYPE_002 CRANK_TYPE_003
      CRANK_RUNTIME_001 CRANK_RUNTIME_002
      CRANK_TRACE_001 CRANK_TRACE_002
      CRANK_META_001 CRANK_META_002 CRANK_META_003 CRANK_META_004
      CRANK_SETUP_001 CRANK_SETUP_002
    )

    test "every v1 code is present (catalog has not shrunk)" do
      catalog_codes = MapSet.new(Enum.map(Catalog.all(), & &1.code))

      for code <- @v1_codes do
        assert MapSet.member?(catalog_codes, code),
               "v1 frozen code #{code} missing from catalog — removing codes requires a major version bump"
      end
    end
  end
end
