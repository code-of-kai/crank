defmodule Crank.SuppressionsTest do
  use ExUnit.Case, async: true

  alias Crank.Errors.Violation
  alias Crank.Suppressions

  describe "parse/1 — happy path" do
    test "parses a valid suppression with reason on the next line" do
      source = """
      defmodule X do
        # crank-allow: CRANK_PURITY_004
        # reason: dev-only debug timestamp
        @debug_now DateTime.utc_now()
      end
      """

      {table, meta} = Suppressions.parse(source)

      assert meta == []

      # The suppression covers the line where `@debug_now` lives
      suppression = Map.get(table, 4)
      assert %{reason: "dev-only debug timestamp"} = suppression
      assert MapSet.member?(suppression.codes, "CRANK_PURITY_004")
    end

    test "parses multiple codes in one annotation" do
      source = """
      # crank-allow: CRANK_PURITY_004, CRANK_PURITY_005
      # reason: integration test fixture sampling time and spawning workers
      do_something()
      """

      {table, meta} = Suppressions.parse(source)
      assert meta == []

      suppression = table[3]
      assert MapSet.member?(suppression.codes, "CRANK_PURITY_004")
      assert MapSet.member?(suppression.codes, "CRANK_PURITY_005")
    end

    test "skips blank lines and additional comments when finding the target" do
      source = """
      # crank-allow: CRANK_PURITY_004
      # reason: explained
      #
      DateTime.utc_now()
      """

      {table, meta} = Suppressions.parse(source)
      assert meta == []
      assert Map.has_key?(table, 4)
    end
  end

  describe "parse/1 — meta violations" do
    test "CRANK_META_001 when reason is missing" do
      source = """
      # crank-allow: CRANK_PURITY_004
      DateTime.utc_now()
      """

      {_table, meta} = Suppressions.parse(source)

      assert [%{code: "CRANK_META_001", line: 1}] = meta
    end

    test "CRANK_META_002 when code is unknown" do
      source = """
      # crank-allow: CRANK_BOGUS_999
      # reason: reasoning
      DateTime.utc_now()
      """

      {_table, meta} = Suppressions.parse(source)

      assert Enum.any?(meta, &(&1.code == "CRANK_META_002"))
    end

    test "CRANK_META_003 when no following code line within 3 lines" do
      source = """
      # crank-allow: CRANK_PURITY_004
      # reason: reasoning
      """

      # The annotation is at line 1, reason at 2; no code line follows.
      {_table, meta} = Suppressions.parse(source)
      assert Enum.any?(meta, &(&1.code == "CRANK_META_003"))
    end

    test "CRANK_META_004 when code is for a wrong layer (topology in source)" do
      source = """
      # crank-allow: CRANK_DEP_001
      # reason: misuse of suppression
      do_something()
      """

      {_table, meta} = Suppressions.parse(source)
      assert Enum.any?(meta, &(&1.code == "CRANK_META_004"))
    end

    test "CRANK_META_004 mentions the correct mechanism" do
      source = """
      # crank-allow: CRANK_PURITY_007
      # reason: misuse — runtime trace code
      do_something()
      """

      {_table, meta} = Suppressions.parse(source)
      [violation] = Enum.filter(meta, &(&1.code == "CRANK_META_004"))
      assert violation.message =~ ":allow"
    end
  end

  describe "suppressed?/2" do
    test "returns true when a violation's line is in the table and code matches" do
      source = """
      # crank-allow: CRANK_PURITY_004
      # reason: ok
      DateTime.utc_now()
      """

      {table, []} = Suppressions.parse(source)

      violation = %Violation{
        code: "CRANK_PURITY_004",
        severity: :error,
        rule: :turn_purity_nondeterminism,
        location: %{file: "x.ex", line: 3},
        fix: %{category: "x", doc_url: "x"}
      }

      assert Suppressions.suppressed?(violation, table)
    end

    test "returns false when violation's code doesn't match the suppression" do
      source = """
      # crank-allow: CRANK_PURITY_004
      # reason: ok
      DateTime.utc_now()
      """

      {table, []} = Suppressions.parse(source)

      violation = %Violation{
        code: "CRANK_PURITY_005",
        severity: :error,
        rule: :turn_purity_process_comm,
        location: %{file: "x.ex", line: 3},
        fix: %{category: "x", doc_url: "x"}
      }

      refute Suppressions.suppressed?(violation, table)
    end

    test "returns false when line is not in the table" do
      violation = %Violation{
        code: "CRANK_PURITY_004",
        severity: :error,
        rule: :turn_purity_nondeterminism,
        location: %{file: "x.ex", line: 99},
        fix: %{category: "x", doc_url: "x"}
      }

      assert Suppressions.suppressed?(violation, %{}) == false
    end
  end
end
