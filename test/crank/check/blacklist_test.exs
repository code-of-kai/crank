defmodule Crank.Check.BlacklistTest do
  use ExUnit.Case, async: true

  alias Crank.Check.Blacklist

  describe "match_call/1 — direct module matchers" do
    test "matches Repo.insert!/1" do
      ast = quote do: Repo.insert!(record)
      assert {:violation, "CRANK_PURITY_001", message, doc_url} = Blacklist.match_call(ast)
      assert message =~ "Repo.*"
      assert String.starts_with?(doc_url, "https://hexdocs.pm/crank/")
    end

    test "matches MyApp.Repo.all/1 (alias prefix uses last segment)" do
      ast = quote do: Repo.all(query)
      assert {:violation, "CRANK_PURITY_001", _, _} = Blacklist.match_call(ast)
    end

    test "does not match Repository (similar name; not on list)" do
      ast = quote do: Repository.fetch(id)
      assert Blacklist.match_call(ast) == nil
    end
  end

  describe "match_call/1 — prefix matchers" do
    test "matches Ecto.Query.from/2" do
      ast = quote do: Ecto.Query.from(u in User, where: u.active)
      assert {:violation, "CRANK_PURITY_001", _, _} = Blacklist.match_call(ast)
    end

    test "matches Logger.info/1" do
      ast = quote do: Logger.info("hello")
      assert {:violation, "CRANK_PURITY_003", _, _} = Blacklist.match_call(ast)
    end

    test "matches File.read!/1" do
      ast = quote do: File.read!("config.json")
      assert {:violation, "CRANK_PURITY_006", _, _} = Blacklist.match_call(ast)
    end
  end

  describe "match_call/1 — Erlang module matchers" do
    test "matches :rand.uniform/0" do
      ast = quote do: :rand.uniform()
      assert {:violation, "CRANK_PURITY_004", _, _} = Blacklist.match_call(ast)
    end

    test "matches :ets.lookup/2" do
      ast = quote do: :ets.lookup(:my_table, :key)
      assert {:violation, "CRANK_PURITY_006", _, _} = Blacklist.match_call(ast)
    end

    test "matches :persistent_term.get/1" do
      ast = quote do: :persistent_term.get(:key)
      assert {:violation, "CRANK_PURITY_006", _, _} = Blacklist.match_call(ast)
    end
  end

  describe "match_call/1 — exact MFA matchers" do
    test "matches DateTime.utc_now/0" do
      ast = quote do: DateTime.utc_now()
      assert {:violation, "CRANK_PURITY_004", _, _} = Blacklist.match_call(ast)
    end

    test "matches DateTime.utc_now/1" do
      ast = quote do: DateTime.utc_now(:second)
      assert {:violation, "CRANK_PURITY_004", _, _} = Blacklist.match_call(ast)
    end

    test "does not match DateTime.from_iso8601/1 (not on list)" do
      ast = quote do: DateTime.from_iso8601("2026-05-04T12:00:00Z")
      assert Blacklist.match_call(ast) == nil
    end
  end

  describe "match_call/1 — any-arity matchers" do
    test "matches Process.put/2" do
      ast = quote do: Process.put(:key, :value)
      assert {:violation, "CRANK_PURITY_006", _, _} = Blacklist.match_call(ast)
    end

    test "matches String.to_atom/1" do
      ast = quote do: String.to_atom("foo")
      assert {:violation, "CRANK_PURITY_006", _, _} = Blacklist.match_call(ast)
    end

    test "does not match String.to_existing_atom/1 (not on list — safe variant)" do
      ast = quote do: String.to_existing_atom("foo")
      assert Blacklist.match_call(ast) == nil
    end

    test "does not match String.split/2 (similar shape; pure)" do
      ast = quote do: String.split("hello world", " ")
      assert Blacklist.match_call(ast) == nil
    end
  end

  describe "match_call/1 — pure stdlib (no false positives)" do
    test "Map.put/3 passes" do
      ast = quote do: Map.put(memory, :key, :value)
      assert Blacklist.match_call(ast) == nil
    end

    test "Enum.map/2 passes" do
      ast = quote do: Enum.map([1, 2, 3], &(&1 * 2))
      assert Blacklist.match_call(ast) == nil
    end

    test "List.first/1 passes" do
      ast = quote do: List.first([1, 2, 3])
      assert Blacklist.match_call(ast) == nil
    end

    test "Integer.parse/1 passes" do
      ast = quote do: Integer.parse("42")
      assert Blacklist.match_call(ast) == nil
    end
  end

  describe "all/0 and count/0" do
    test "all/0 returns the full entry list" do
      assert is_list(Blacklist.all())
      assert length(Blacklist.all()) > 30
    end

    test "count/0 matches all/0 length" do
      assert Blacklist.count() == length(Blacklist.all())
    end
  end
end
