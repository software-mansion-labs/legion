defmodule Legion.Sandbox.LuaTest.EchoTool do
  use Legion.Tool

  def description, do: "EchoTool - test bridge tool."

  def add(a, b), do: a + b
  def add(a, b, c), do: a + b + c
  def shape(value), do: %{received: value, tag: :ok}
  def module_check(module), do: %{is_atom: is_atom(module), name: inspect(module)}
  def pair, do: {:ok, 42}
  def boom, do: raise(ArgumentError, "tool exploded")
end

defmodule Legion.Sandbox.LuaTest do
  use ExUnit.Case

  doctest Legion.Sandbox.Lua, import: true

  alias Legion.Sandbox.Lua
  alias Legion.Sandbox.LuaTest.EchoTool

  test "returns result and reusable bindings" do
    assert {:ok, {nil, bindings}} = Lua.execute("x = 40", 15_000)
    assert {:ok, {42, _}} = Lua.execute("return x + 2", 15_000, [], bindings)
  end

  test "chunk without return yields nil" do
    assert {:ok, {nil, _}} = Lua.execute("y = 1", 15_000)
  end

  test "multiple return values become a list" do
    assert {:ok, {[1, 2], _}} = Lua.execute("return 1, 2", 15_000)
  end

  test "local variables do not persist, globals do" do
    {:ok, {nil, bindings}} = Lua.execute("local a = 1\nb = 2", 15_000)
    assert {:ok, {nil, _}} = Lua.execute("return a", 15_000, [], bindings)
    assert {:ok, {2, _}} = Lua.execute("return b", 15_000, [], bindings)
  end

  test "bindings survive the term round-trip a store does" do
    {:ok, {nil, bindings}} = Lua.execute("count = EchoTool.add(1, 2)", 15_000, [EchoTool])

    revived = bindings |> :erlang.term_to_binary() |> :erlang.binary_to_term()

    assert {:ok, {3, _}} = Lua.execute("return count", 15_000, [EchoTool], revived)

    assert {:ok, {4, _}} =
             Lua.execute("return EchoTool.add(count, 1)", 15_000, [EchoTool], revived)

    assert Lua.binding_names(revived) == ["count"]
  end

  test "binding_names lists user globals only" do
    {:ok, {nil, bindings}} = Lua.execute("count = 1\nitems = {1, 2}", 15_000, [EchoTool])
    assert Enum.sort(Lua.binding_names(bindings)) == ["count", "items"]
    assert Lua.binding_names([]) == []
  end

  test "parse errors are caught by check" do
    assert {:error, message} = Lua.execute("local x =;", 15_000)
    assert message =~ "Lua parse error"
  end

  test "bare-expression mistake gets a return hint" do
    assert {:error, message} = Lua.execute("x = 1\nx", 15_000)
    assert message =~ "return <expression>"
  end

  test "tool tables passed as arguments resolve to their module atom" do
    assert {:ok, {value, _}} =
             Lua.execute("return EchoTool.module_check(EchoTool)", 15_000, [EchoTool])

    assert value == %{"is_atom" => true, "name" => "Legion.Sandbox.LuaTest.EchoTool"}
  end

  test "runtime errors are returned as error strings" do
    assert {:error, message} = Lua.execute("error('boom')", 15_000)
    assert message =~ "boom"
  end

  test "io and os escapes are sandboxed" do
    assert {:error, message} = Lua.execute("os.getenv('HOME')", 15_000)
    assert message =~ "sandboxed"

    assert {:error, message} = Lua.execute("print('hi')", 15_000)
    assert message =~ "sandboxed"
  end

  test "debug library is sandboxed" do
    assert {:error, message} = Lua.execute("return debug.setmetatable", 15_000)
    assert message =~ "invalid index"

    assert {:error, message} = Lua.execute("return debug(1)", 15_000)
    assert message =~ "sandboxed"
  end

  test "dead tables are collected instead of accumulating in the state" do
    {:ok, {nil, baseline}} = Lua.execute("x = 1", 15_000)

    churned =
      Enum.reduce(1..20, baseline, fn _i, bindings ->
        {:ok, {nil, next}} =
          Lua.execute("local t = {}\nfor i = 1, 100 do t[i] = i end", 15_000, [], bindings)

        next
      end)

    baseline_size = byte_size(:erlang.term_to_binary(baseline))
    churned_size = byte_size(:erlang.term_to_binary(churned))

    assert churned_size < baseline_size * 1.5
  end

  test "tool functions are callable with arity dispatch" do
    assert {:ok, {3, _}} = Lua.execute("return EchoTool.add(1, 2)", 15_000, [EchoTool])
    assert {:ok, {6, _}} = Lua.execute("return EchoTool.add(1, 2, 3)", 15_000, [EchoTool])
  end

  test "wrong tool arity returns a helpful error" do
    assert {:error, message} = Lua.execute("return EchoTool.add(1)", 15_000, [EchoTool])
    assert message =~ "EchoTool.add takes 2 or 3 argument(s), got 1"
  end

  test "lua tables arrive as maps or lists, results convert back" do
    assert {:ok, {value, _}} =
             Lua.execute("return EchoTool.shape({name = 'ada', tags = {1, 2}})", 15_000, [
               EchoTool
             ])

    assert value == %{"received" => %{"name" => "ada", "tags" => [1, 2]}, "tag" => "ok"}
  end

  test "tuple results become arrays" do
    assert {:ok, {["ok", 42], _}} = Lua.execute("return EchoTool.pair()", 15_000, [EchoTool])
  end

  test "tool exceptions surface with the tool name" do
    assert {:error, message} = Lua.execute("EchoTool.boom()", 15_000, [EchoTool])
    assert message =~ "EchoTool.boom"
    assert message =~ "tool exploded"
  end

  test "meta functions from Legion.Tool are not bridged" do
    assert {:error, _message} = Lua.execute("return EchoTool.description()", 15_000, [EchoTool])
  end

  test "timeout kills the evaluation" do
    assert {:error, :timeout} = Lua.execute("while true do end", 100)
  end

  test "reduction budget kills a busy loop" do
    assert {:error, message} =
             Lua.execute("local n = 0\nfor i = 1, 100000000 do n = n + 1 end", 60_000, [], [],
               max_reductions: 1_000_000
             )

    assert message =~ "reduction (CPU) limit"
  end

  test "prompt_info describes the Lua environment" do
    info = Lua.prompt_info()
    assert info.language == "Lua"
    assert info.constraints =~ "global"
    assert info.tool_usage =~ "Lua"
  end
end
