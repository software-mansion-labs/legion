defmodule Legion.Store.PostgresDbTest do
  @moduledoc """
  Exercises the generated Postgres store against a real database, so the SQL it
  issues - the `ON CONFLICT` upsert in particular - is verified for real rather
  than shape-matched against a fake.
  """
  use ExUnit.Case, async: false

  defmodule Repo do
    def query!(sql, params), do: Postgrex.query!(:legion_store_test, sql, params)
  end

  defmodule Store do
    use Legion.Store.Postgres, repo: Legion.Store.PostgresDbTest.Repo
  end

  setup do
    Postgrex.query!(:legion_store_test, "TRUNCATE legion_agents", [])
    :ok
  end

  test "round-trips a snapshot through a real bytea column" do
    snapshot = %{messages: [%{role: "user", content: "hi"}], bindings: [x: 42]}

    assert :ok = Store.save("user_42", snapshot)
    assert {:ok, ^snapshot} = Store.load("user_42")
  end

  test "load/1 returns :error when the row is absent" do
    assert :error = Store.load("missing")
  end

  test "save/2 upserts on conflict - the latest snapshot wins" do
    assert :ok = Store.save("user_42", %{messages: [], bindings: [v: 1]})
    assert :ok = Store.save("user_42", %{messages: [], bindings: [v: 2]})

    assert {:ok, %{bindings: [v: 2]}} = Store.load("user_42")
  end
end
