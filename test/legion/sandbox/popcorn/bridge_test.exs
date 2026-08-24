defmodule Legion.Sandbox.Popcorn.BridgeTest do
  use ExUnit.Case, async: true

  alias Legion.Sandbox.Popcorn.Bridge
  alias Legion.Test.Support.EchoTool

  describe "manifest/1" do
    test "describes tool modules with callable functions" do
      assert [
               %{
                 name: "EchoTool",
                 module: "Elixir.Legion.Test.Support.EchoTool",
                 functions: functions
               }
             ] =
               Bridge.manifest([EchoTool])

      assert %{name: "echo", arities: [1]} in functions
      assert %{name: "add", arities: [2]} in functions
      assert %{name: "boom", arities: [0]} in functions
      refute Enum.any?(functions, &(&1.name == "description"))
      refute Enum.any?(functions, &(&1.name == "extra_allowed_modules"))
    end

    test "non-tool modules are reference-only" do
      assert [%{name: "Enum", functions: []}] = Bridge.manifest([Enum])
    end
  end

  describe "encode/1" do
    test "tuples become lists, atoms become strings" do
      assert Bridge.encode({:ok, 42}) == ["ok", 42]
    end

    test "structs become plain string-keyed maps" do
      assert Bridge.encode(%URI{scheme: "https"})["scheme"] == "https"
    end

    test "maps get string keys, values recurse" do
      assert Bridge.encode(%{1 => :one, status: {:ok, :done}}) ==
               %{"status" => ["ok", "done"], "1" => "one"}
    end

    test "booleans, nil, numbers, and binaries pass through" do
      assert Bridge.encode([true, false, nil, 1.5, "s"]) == [true, false, nil, 1.5, "s"]
    end

    test "unencodable values become inspect strings" do
      assert Bridge.encode(self()) == inspect(self())
    end
  end

  describe "decode/2" do
    test "resolves module markers for allowed modules only" do
      refs = Bridge.module_refs([EchoTool])
      assert Bridge.decode(%{"__legion_module" => "EchoTool"}, refs) == EchoTool

      assert Bridge.decode(%{"__legion_module" => "System"}, refs) == %{
               "__legion_module" => "System"
             }
    end

    test "recurses through lists and maps" do
      refs = Bridge.module_refs([EchoTool])

      assert Bridge.decode([%{"tool" => %{"__legion_module" => "EchoTool"}}], refs) ==
               [%{"tool" => EchoTool}]
    end
  end
end
