defmodule Crank.ErrorsTest do
  use ExUnit.Case, async: true

  alias Crank.Errors
  alias Crank.Errors.Violation

  describe "build/2" do
    test "constructs a violation from a catalog code" do
      v = Errors.build("CRANK_PURITY_001", location: %{file: "lib/x.ex", line: 42})

      assert %Violation{
               code: "CRANK_PURITY_001",
               severity: :error,
               rule: :turn_purity_direct,
               location: %{file: "lib/x.ex", line: 42}
             } = v

      assert String.starts_with?(v.fix.doc_url, "https://hexdocs.pm/crank/CRANK_PURITY_001")
    end

    test "raises on unknown code" do
      assert_raise ArgumentError, fn -> Errors.build("CRANK_DOES_NOT_EXIST") end
    end
  end

  describe "format_pretty/1" do
    test "includes the code, file, line, and doc URL" do
      v =
        Errors.build("CRANK_PURITY_004",
          location: %{file: "lib/order.ex", line: 17, column: 9},
          violating_call: %{module: DateTime, function: :utc_now, arity: 0}
        )

      pretty = Errors.format_pretty(v)

      assert pretty =~ "[CRANK_PURITY_004]"
      assert pretty =~ "lib/order.ex:17:9"
      assert pretty =~ "https://hexdocs.pm/crank/CRANK_PURITY_004"
    end

    test "renders before/after fix snippets when present" do
      v =
        Errors.build("CRANK_PURITY_001",
          location: %{file: "x.ex", line: 1},
          fix_before: "Repo.insert!(record)",
          fix_after: "{:next, :submitted, %{memory | record: record}}"
        )

      pretty = Errors.format_pretty(v)

      assert pretty =~ "Wrong:"
      assert pretty =~ "Repo.insert!"
      assert pretty =~ "Right:"
      assert pretty =~ ":next"
    end
  end

  describe "format_structured/1" do
    test "produces a JSON-serialisable map with stable schema" do
      v =
        Errors.build("CRANK_DEP_001",
          location: %{file: "lib/order.ex", line: 5, column: 3, function: "turn/3"},
          violating_call: %{module: MyApp.Repo, function: :insert!, arity: 1},
          context: "MyApp.Order"
        )

      structured = Errors.format_structured(v)

      assert structured["code"] == "CRANK_DEP_001"
      assert structured["severity"] == "error"
      assert structured["rule"] == "dependency_direction"
      assert structured["location"]["file"] == "lib/order.ex"
      assert structured["location"]["line"] == 5
      assert structured["violating_call"]["module"] == "MyApp.Repo"
      assert structured["violating_call"]["function"] == "insert!"
      assert structured["violating_call"]["arity"] == 1
      assert structured["context"] == "MyApp.Order"
      assert is_binary(structured["fix"]["doc_url"])
    end

    test "round-trips: format_structured can be JSON-encoded if a JSON lib is available" do
      v = Errors.build("CRANK_PURITY_005", location: %{file: "x.ex", line: 1})
      structured = Errors.format_structured(v)

      # Manual sanity: every value is JSON-shaped (string/number/nil/map)
      assert deeply_json_compatible?(structured)
    end
  end

  describe "to_compile_error/1" do
    test "returns a CompileError with the file, line, and pretty description" do
      v =
        Errors.build("CRANK_PURITY_001",
          location: %{file: "lib/order.ex", line: 42}
        )

      err = Errors.to_compile_error(v)
      assert %CompileError{file: "lib/order.ex", line: 42} = err
      assert err.description =~ "[CRANK_PURITY_001]"
    end
  end

  defp deeply_json_compatible?(value) when is_map(value) do
    Enum.all?(value, fn {k, v} -> is_binary(k) and deeply_json_compatible?(v) end)
  end

  defp deeply_json_compatible?(value) when is_list(value) do
    Enum.all?(value, &deeply_json_compatible?/1)
  end

  defp deeply_json_compatible?(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value),
       do: true

  defp deeply_json_compatible?(_), do: false
end
