defmodule Legion.SandboxTest do
  use ExUnit.Case

  doctest Legion.Sandbox, import: true

  test "returns result and bindings" do
    assert {:ok, {5, bindings}} = Legion.Sandbox.execute("a = 2 + 2\na + 1", 15_000)
    assert Keyword.get(bindings, :a) == 4
  end

  test "accepts bindings from a previous execution" do
    {:ok, {_result, bindings}} = Legion.Sandbox.execute("posts = [1, 2, 3]", 15_000)
    assert {:ok, {6, _}} = Legion.Sandbox.execute("Enum.sum(posts)", 15_000, [], bindings)
  end

  test "bindings accumulate across calls" do
    {:ok, {_, b1}} = Legion.Sandbox.execute("x = 10", 15_000)
    {:ok, {_, b2}} = Legion.Sandbox.execute("y = 20", 15_000, [], b1)
    assert {:ok, {30, _}} = Legion.Sandbox.execute("x + y", 15_000, [], b2)
  end

  test "throw returns an error tuple instead of crashing" do
    assert {:error, {:throw, :foo}} = Legion.Sandbox.execute("throw(:foo)", 15_000)
  end

  test "exit returns an error tuple instead of crashing" do
    assert {:error, {:exit, :boom}} = Legion.Sandbox.execute("exit(:boom)", 15_000)
  end

  test "eval exceeding the heap budget is killed with a memory error" do
    assert {:error, message} =
             Legion.Sandbox.execute("Enum.to_list(1..50_000_000)", 15_000, [], [],
               max_heap: 10_000_000
             )

    assert message =~ "memory limit"
  end

  test "a brutal kill without a heap budget reports a crash, not a memory limit" do
    # The AST checker blocks Process for generated code; allowing it here is
    # the only way to provoke the :killed exit an external kill would cause.
    assert {:error, {:process_crashed, :killed}} =
             Legion.Sandbox.execute("Process.exit(self(), :kill)", 15_000, [Process])
  end

  test "heap budget leaves ordinary evals untouched" do
    assert {:ok, {499_500, _}} =
             Legion.Sandbox.execute("Enum.sum(1..999)", 15_000, [], [], max_heap: 10_000_000)
  end

  test "eval exceeding the reduction budget is killed with a CPU error" do
    code = "Enum.reduce(1..100_000_000, 0, fn n, acc -> acc + n end)"

    assert {:error, message} =
             Legion.Sandbox.execute(code, 60_000, [], [], max_reductions: 1_000_000)

    assert message =~ "reduction (CPU) limit"
  end

  test "reduction budget leaves ordinary evals untouched" do
    assert {:ok, {499_500, _}} =
             Legion.Sandbox.execute("Enum.sum(1..999)", 15_000, [], [], max_reductions: 1_000_000)
  end

  test "compile error surfaces diagnostics instead of the generic wrapper message" do
    code = ~S|x = 1
String.upcase(t)|

    assert {:error, msg} = Legion.Sandbox.execute(code, 15_000)
    assert is_binary(msg)
    assert msg =~ "undefined variable"
    assert msg =~ "\"t\""
    refute msg =~ "cannot compile file"
  end

  test "runtime exception is returned as the original struct" do
    assert {:error, %RuntimeError{message: "boom"}} =
             Legion.Sandbox.execute(~S|raise "boom"|, 15_000)
  end

  test "Calendar module is callable from sandboxed code" do
    code = ~S|Calendar.strftime(~D[2026-04-17], "%Y-%m-%d")|
    assert {:ok, {"2026-04-17", _}} = Legion.Sandbox.execute(code, 15_000)
  end
end
