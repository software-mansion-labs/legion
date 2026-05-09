defmodule Legion.Sandbox.ASTCheckerTest do
  use ExUnit.Case

  alias Legion.Sandbox.ASTChecker

  # --- Safe operations ---

  test "literals and arithmetic" do
    assert :ok = ASTChecker.check("1 + 2 * 3", [])
  end

  test "variable assignment and reuse" do
    assert :ok = ASTChecker.check("x = 10\nx * 2", [])
  end

  test "builtin Enum call" do
    assert :ok = ASTChecker.check("Enum.map([1, 2, 3], & &1 + 1)", [])
  end

  test "builtin String call" do
    assert :ok = ASTChecker.check("String.upcase(\"hello\")", [])
  end

  test "builtin Map call" do
    assert :ok = ASTChecker.check("Map.get(%{a: 1}, :a)", [])
  end

  test "erlang math module is allowed" do
    assert :ok = ASTChecker.check(":math.sqrt(4.0)", [])
  end

  test ":erlang module is not in the built-in allow-list" do
    assert {:error, msg} = ASTChecker.check(":erlang.length([1, 2, 3])", [])
    assert msg =~ ":erlang"
  end

  test "caller-provided module is allowed" do
    assert :ok = ASTChecker.check("MyTool.run(1)", [MyTool])
  end

  test "caller-provided module not allowed without explicit permission" do
    assert {:error, msg} = ASTChecker.check("MyTool.run(1)", [])
    assert msg =~ "MyTool is not allowed"
  end

  test "nested builtin calls" do
    assert :ok = ASTChecker.check("Enum.map([1, 2], fn x -> Integer.to_string(x) end)", [])
  end

  # --- Disallowed Elixir modules ---

  test "File module is blocked" do
    assert {:error, msg} = ASTChecker.check("File.read!(\"/etc/passwd\")", [])
    assert msg =~ "File"
  end

  test "System module is blocked" do
    assert {:error, msg} = ASTChecker.check("System.halt()", [])
    assert msg =~ "System"
  end

  test "IO module is blocked" do
    assert {:error, msg} = ASTChecker.check("IO.puts(\"hi\")", [])
    assert msg =~ "IO"
  end

  test "Code module is blocked" do
    assert {:error, msg} = ASTChecker.check("Code.eval_string(\"1+1\")", [])
    assert msg =~ "Code"
  end

  test "Process module is blocked" do
    assert {:error, msg} = ASTChecker.check("Process.exit(self(), :kill)", [])
    assert msg =~ "Process"
  end

  # --- Disallowed Erlang modules ---

  test ":os module is blocked" do
    assert {:error, msg} = ASTChecker.check(":os.getenv(\"PATH\")", [])
    assert msg =~ ":os"
  end

  test ":file module is blocked" do
    assert {:error, msg} = ASTChecker.check(":file.read_file(\"/etc/passwd\")", [])
    assert msg =~ ":file"
  end

  test ":io module is blocked" do
    assert {:error, msg} = ASTChecker.check(":io.format(\"hello~n\")", [])
    assert msg =~ ":io"
  end

  # --- Forbidden special forms ---

  test "defmodule is forbidden" do
    assert {:error, msg} = ASTChecker.check("defmodule Foo do end", [])
    assert msg =~ "defmodule"
  end

  test "spawn is forbidden" do
    assert {:error, msg} = ASTChecker.check("spawn(fn -> :ok end)", [])
    assert msg =~ "spawn"
  end

  test "send is forbidden" do
    assert {:error, msg} = ASTChecker.check("send(self(), :hi)", [])
    assert msg =~ "send"
  end

  test "receive is forbidden" do
    code = """
    receive do
      msg -> msg
    end
    """

    assert {:error, msg} = ASTChecker.check(code, [])
    assert msg =~ "receive"
  end

  test "quote is forbidden" do
    assert {:error, msg} = ASTChecker.check("quote do: 1 + 1", [])
    assert msg =~ "quote"
  end

  test "import is forbidden" do
    assert {:error, msg} = ASTChecker.check("import Enum", [])
    assert msg =~ "import"
  end

  test "use is forbidden" do
    assert {:error, msg} = ASTChecker.check("use GenServer", [])
    assert msg =~ "use"
  end

  test "require is forbidden" do
    assert {:error, msg} = ASTChecker.check("require Logger", [])
    assert msg =~ "require"
  end

  test "alias inside code string is forbidden" do
    assert {:error, msg} = ASTChecker.check("alias File, as: String", [])
    assert msg =~ "alias"
  end

  test "alias renaming forbidden module to allowed name is blocked" do
    assert {:error, _} = ASTChecker.check("alias :os, as: SafeModule\nSafeModule.cmd(\"ls\")", [])
  end

  test "aliasing allowed modules works via allowed_modules list" do
    alias Some.Namespace.MyTool
    assert :ok = ASTChecker.check("MyTool.run(1)", [MyTool])
    assert {:error, _} = ASTChecker.check("Other.run(1)", [Some.Namespace.MyTool])
  end

  # --- Forbidden functions on allowed modules ---

  test "Kernel.spawn is forbidden" do
    assert {:error, msg} = ASTChecker.check("Kernel.spawn(fn -> :ok end)", [])
    assert msg =~ "Kernel.spawn"
  end

  test "Kernel.spawn_link is forbidden" do
    assert {:error, msg} = ASTChecker.check("Kernel.spawn_link(fn -> :ok end)", [])
    assert msg =~ "Kernel.spawn_link"
  end

  test "Kernel.send is forbidden" do
    assert {:error, msg} = ASTChecker.check("Kernel.send(self(), :hi)", [])
    assert msg =~ "Kernel.send"
  end

  test "Kernel.apply is forbidden" do
    assert {:error, msg} = ASTChecker.check("Kernel.apply(IO, :puts, [\"hi\"])", [])
    assert msg =~ "Kernel.apply"
  end

  test "Kernel.exit is allowed (mirrors bare exit; the host already isolates execution)" do
    assert :ok = ASTChecker.check("Kernel.exit(:normal)", [])
  end

  test ":erlang.spawn is forbidden" do
    assert {:error, msg} = ASTChecker.check(":erlang.spawn(fn -> :ok end)", [])
    assert msg =~ ":erlang"
  end

  test ":erlang.spawn_opt is forbidden" do
    assert {:error, msg} = ASTChecker.check(":erlang.spawn_opt(fn -> :ok end, [])", [])
    assert msg =~ ":erlang"
  end

  test ":erlang.apply is forbidden" do
    assert {:error, msg} = ASTChecker.check(":erlang.apply(IO, :puts, [\"hi\"])", [])
    assert msg =~ ":erlang"
  end

  test ":erlang.get is forbidden" do
    assert {:error, msg} = ASTChecker.check(":erlang.get()", [])
    assert msg =~ ":erlang"
  end

  test ":erlang.put is forbidden" do
    assert {:error, msg} = ASTChecker.check(":erlang.put(:key, :value)", [])
    assert msg =~ ":erlang"
  end

  test ":erlang.process_flag is forbidden" do
    assert {:error, msg} = ASTChecker.check(":erlang.process_flag(:trap_exit, true)", [])
    assert msg =~ ":erlang"
  end

  test ":erlang.list_to_atom is forbidden" do
    assert {:error, msg} = ASTChecker.check(":erlang.list_to_atom(~c\"boom\")", [])
    assert msg =~ ":erlang"
  end

  test ":erlang.system_info is forbidden" do
    assert {:error, msg} = ASTChecker.check(":erlang.system_info(:process_count)", [])
    assert msg =~ ":erlang"
  end

  test "String.to_atom is forbidden" do
    assert {:error, msg} = ASTChecker.check("String.to_atom(\"hi\")", [])
    assert msg =~ "String.to_atom"
  end

  test "String.to_existing_atom is forbidden (closes the fake-struct atom-reconstruction bypass)" do
    assert {:error, msg} = ASTChecker.check("String.to_existing_atom(\"ok\")", [])
    assert msg =~ "String.to_existing_atom"
  end

  test "List.to_atom is forbidden" do
    assert {:error, msg} = ASTChecker.check("List.to_atom(~c\"hi\")", [])
    assert msg =~ "List.to_atom"
  end

  test "List.to_existing_atom is forbidden (closes the fake-struct atom-reconstruction bypass)" do
    assert {:error, msg} = ASTChecker.check("List.to_existing_atom(~c\"ok\")", [])
    assert msg =~ "List.to_existing_atom"
  end

  test "node/0 is forbidden (denies sandbox the BEAM node atom)" do
    assert {:error, msg} = ASTChecker.check("node()", [])
    assert msg =~ "node"
  end

  test "node/1 is forbidden" do
    assert {:error, msg} = ASTChecker.check("node(self())", [])
    assert msg =~ "node"
  end

  test "Kernel.node is forbidden (qualified form)" do
    assert {:error, msg} = ASTChecker.check("Kernel.node()", [])
    assert msg =~ "Kernel.node"
  end

  test "Calendar.put_time_zone_database is forbidden" do
    assert {:error, msg} = ASTChecker.check("Calendar.put_time_zone_database(Some.DB)", [Some.DB])
    assert msg =~ "Calendar.put_time_zone_database"
  end

  test "__ENV__ is forbidden" do
    assert {:error, msg} = ASTChecker.check("__ENV__", [])
    assert msg =~ "__ENV__"
  end

  test "def is forbidden" do
    assert {:error, msg} = ASTChecker.check("def foo(x), do: x + 1", [])
    assert msg =~ "def"
  end

  test "defp is forbidden" do
    assert {:error, msg} = ASTChecker.check("defp foo(x), do: x + 1", [])
    assert msg =~ "defp"
  end

  # --- Bypass attempts ---

  test "variable-as-module dispatch to :erlang is forbidden" do
    code = """
    m = :erlang
    m.spawn_opt(fn -> :ok end, [])
    """

    assert {:error, _} = ASTChecker.check(code, [])
  end

  test "variable-as-module dispatch to a disallowed module is forbidden" do
    code = """
    m = File
    m.read!("/etc/passwd")
    """

    assert {:error, _} = ASTChecker.check(code, [])
  end

  test "variable-as-module dispatch even to an allowed module is forbidden" do
    code = """
    m = Enum
    m.map([1, 2, 3], & &1 + 1)
    """

    assert {:error, _} = ASTChecker.check(code, [])
  end

  test "captured forbidden function is forbidden" do
    assert {:error, _} = ASTChecker.check("f = &:erlang.spawn_opt/2", [])
  end

  test "captured forbidden Kernel function is forbidden" do
    assert {:error, _} = ASTChecker.check("f = &Kernel.spawn/1", [])
  end

  test "map field access via dot syntax is rejected (use m[:key] instead)" do
    assert {:error, _} = ASTChecker.check("m = %{a: 1}\nm.a", [])
  end

  test "nested dot map access is rejected (use m[:a][:b])" do
    assert {:error, _} = ASTChecker.check("m = %{a: %{b: 2}}\nm.a.b", [])
  end

  test "map field access via Access protocol is allowed" do
    assert :ok = ASTChecker.check("m = %{a: 1}\nm[:a]", [])
  end

  test "nested map field access via Access protocol is allowed" do
    assert :ok = ASTChecker.check("m = %{a: %{b: 2}}\nm[:a][:b]", [])
  end

  test "Map.fetch! is allowed" do
    assert :ok = ASTChecker.check("m = %{a: 1}\nMap.fetch!(m, :a)", [])
  end

  # --- Edge cases ---

  test "syntax error returns parse error" do
    assert {:error, msg} = ASTChecker.check("def foo(", [])
    assert msg =~ "Parse error"
  end

  test "code exceeding the size cap is rejected" do
    big = String.duplicate("x = 1\n", 20_000)
    assert {:error, msg} = ASTChecker.check(big, [])
    assert msg =~ "exceeds maximum size"
  end

  test "disallowed call nested inside allowed call is caught" do
    assert {:error, _} = ASTChecker.check("Enum.map([1], fn _ -> System.halt() end)", [])
  end

  test "multiple violations only returns one error" do
    assert {:error, _} = ASTChecker.check("File.read!(\"x\") || System.halt()", [])
  end

  # --- Default-deny: previously bypassable cases ---

  describe "Kernel.* macro form bypasses" do
    test "Kernel.def is forbidden" do
      assert {:error, msg} = ASTChecker.check("Kernel.def(foo, do: 1)", [])
      assert msg =~ "Kernel.def"
    end

    test "Kernel.defp is forbidden" do
      assert {:error, msg} = ASTChecker.check("Kernel.defp(foo, do: 1)", [])
      assert msg =~ "Kernel.defp"
    end

    test "Kernel.defmodule is forbidden" do
      assert {:error, msg} = ASTChecker.check("Kernel.defmodule(Foo, do: nil)", [])
      assert msg =~ "Kernel.defmodule"
    end

    test "Kernel.defmacro is forbidden" do
      assert {:error, msg} = ASTChecker.check("Kernel.defmacro(foo, do: 1)", [])
      assert msg =~ "Kernel.defmacro"
    end

    test "Kernel.defstruct is forbidden" do
      assert {:error, msg} = ASTChecker.check("Kernel.defstruct(foo: 1)", [])
      assert msg =~ "Kernel.defstruct"
    end

    test "Kernel.use is forbidden" do
      assert {:error, msg} = ASTChecker.check("Kernel.use(GenServer)", [])
      assert msg =~ "Kernel.use"
    end

    test "Kernel.alias! is forbidden" do
      assert {:error, msg} = ASTChecker.check("Kernel.alias!(File)", [])
      assert msg =~ "Kernel.alias!"
    end

    test "Kernel.var! is forbidden" do
      assert {:error, msg} = ASTChecker.check("Kernel.var!(x)", [])
      assert msg =~ "Kernel.var!"
    end

    test "Kernel.dbg is forbidden" do
      assert {:error, msg} = ASTChecker.check("Kernel.dbg(1 + 1)", [])
      assert msg =~ "Kernel.dbg"
    end

    test "Kernel.binding is forbidden" do
      assert {:error, msg} = ASTChecker.check("Kernel.binding()", [])
      assert msg =~ "Kernel.binding"
    end
  end

  describe "Kernel.* atom-creation function bypasses" do
    test "Kernel.binary_to_atom is forbidden" do
      assert {:error, msg} = ASTChecker.check("Kernel.binary_to_atom(\"x\", :utf8)", [])
      assert msg =~ "Kernel.binary_to_atom"
    end

    test "Kernel.binary_to_existing_atom is forbidden" do
      assert {:error, msg} =
               ASTChecker.check("Kernel.binary_to_existing_atom(\"x\", :utf8)", [])

      assert msg =~ "Kernel.binary_to_existing_atom"
    end

    test "Kernel.list_to_atom is forbidden" do
      assert {:error, msg} = ASTChecker.check("Kernel.list_to_atom(~c\"x\")", [])
      assert msg =~ "Kernel.list_to_atom"
    end

    test "Kernel.list_to_existing_atom is forbidden" do
      assert {:error, msg} = ASTChecker.check("Kernel.list_to_existing_atom(~c\"x\")", [])
      assert msg =~ "Kernel.list_to_existing_atom"
    end
  end

  describe "Kernel.* process / dispatch function bypasses" do
    test "Kernel.spawn_request is forbidden" do
      assert {:error, msg} = ASTChecker.check("Kernel.spawn_request(fn -> :ok end)", [])
      assert msg =~ "Kernel.spawn_request"
    end

    test "Kernel.throw is allowed (mirrors bare throw)" do
      assert :ok = ASTChecker.check("Kernel.throw(:bad)", [])
    end

    test "Kernel.struct is forbidden because it can call __struct__/1 on any module atom" do
      assert {:error, msg} = ASTChecker.check("Kernel.struct(Foo, %{})", [])
      assert msg =~ "Kernel.struct"
    end

    test "Kernel.struct! is forbidden" do
      assert {:error, msg} = ASTChecker.check("Kernel.struct!(Foo, %{})", [])
      assert msg =~ "Kernel.struct!"
    end

    test "Kernel.function_exported? is forbidden" do
      assert {:error, msg} = ASTChecker.check("Kernel.function_exported?(File, :read, 1)", [])
      assert msg =~ "Kernel.function_exported?"
    end
  end

  describe "extra definition forms" do
    test "defstruct is forbidden" do
      assert {:error, msg} = ASTChecker.check("defstruct foo: 1", [])
      assert msg =~ "defstruct"
    end

    test "defexception is forbidden" do
      assert {:error, msg} = ASTChecker.check("defexception []", [])
      assert msg =~ "defexception"
    end

    test "defmacrop is forbidden" do
      assert {:error, msg} = ASTChecker.check("defmacrop foo, do: 1", [])
      assert msg =~ "defmacrop"
    end

    test "defguard is forbidden" do
      assert {:error, msg} = ASTChecker.check("defguard is_x(x) when x > 0", [])
      assert msg =~ "defguard"
    end

    test "defguardp is forbidden" do
      assert {:error, msg} = ASTChecker.check("defguardp is_x(x) when x > 0", [])
      assert msg =~ "defguardp"
    end

    test "defdelegate is forbidden" do
      assert {:error, msg} = ASTChecker.check("defdelegate read(p), to: File", [])
      assert msg =~ "defdelegate"
    end

    test "defoverridable is forbidden" do
      assert {:error, msg} = ASTChecker.check("defoverridable [foo: 0]", [])
      assert msg =~ "defoverridable"
    end

    test "defimpl is forbidden" do
      assert {:error, msg} = ASTChecker.check("defimpl Foo, for: List do end", [])
      assert msg =~ "defimpl"
    end
  end

  describe "context / reflection macros" do
    test "__MODULE__ is forbidden" do
      assert {:error, msg} = ASTChecker.check("__MODULE__", [])
      assert msg =~ "__MODULE__"
    end

    test "__CALLER__ is forbidden" do
      assert {:error, msg} = ASTChecker.check("__CALLER__", [])
      assert msg =~ "__CALLER__"
    end

    test "__DIR__ is forbidden" do
      assert {:error, msg} = ASTChecker.check("__DIR__", [])
      assert msg =~ "__DIR__"
    end

    test "__STACKTRACE__ is forbidden" do
      assert {:error, msg} = ASTChecker.check("__STACKTRACE__", [])
      assert msg =~ "__STACKTRACE__"
    end

    test "binding is forbidden as a bare form" do
      assert {:error, msg} = ASTChecker.check("binding()", [])
      assert msg =~ "binding"
    end
  end

  describe "default-deny on disallowed functions of allowed modules" do
    test "Enum function not in allowlist is rejected" do
      assert {:error, msg} = ASTChecker.check("Enum.zip3([1], [2], [3])", [])
      assert msg =~ "Enum.zip3"
    end

    test "String.zzz_unknown is rejected" do
      # the function name has to exist as an atom for the parser to accept it
      _ = :length
      assert {:error, msg} = ASTChecker.check("String.length_unknown_xx(\"x\")", [])
      assert msg =~ "String."
    end

    test "Atom.to_string is allowed" do
      assert :ok = ASTChecker.check("Atom.to_string(:foo)", [])
    end

    test "Atom.to_charlist is allowed" do
      assert :ok = ASTChecker.check("Atom.to_charlist(:foo)", [])
    end
  end

  describe "tools (caller-supplied modules) are unrestricted" do
    test "any function on a tool module is allowed" do
      assert :ok = ASTChecker.check("MyTool.anything_at_all(1, 2, 3)", [MyTool])
    end

    test "tool modules are matched by tail alias too" do
      assert :ok = ASTChecker.check("MyTool.run(1)", [Some.Namespace.MyTool])
    end
  end

  describe "anonymous function call forms" do
    test "f.() invocation of a binding is allowed" do
      assert :ok = ASTChecker.check("f = fn -> 1 end\nf.()", [])
    end

    test "fn returning a module then dispatch is rejected as dynamic dispatch" do
      assert {:error, msg} =
               ASTChecker.check("(fn -> :erlang end).().spawn(fn -> :ok end)", [])

      assert msg =~ "dynamic dispatch"
    end
  end

  describe "RCE attack vectors" do
    test "no-parens dot on a variable holding a module atom is rejected" do
      code = """
      m = :os
      m.getenv
      """

      assert {:error, _} = ASTChecker.check(code, [])
    end

    test "no-parens dot via System binding is rejected" do
      code = """
      m = System
      m.get_env
      """

      assert {:error, _} = ASTChecker.check(code, [])
    end

    test "capture &m.fun/n where m is a variable is rejected" do
      code = """
      m = :os
      f = &m.cmd/1
      f.(~c"id")
      """

      assert {:error, _} = ASTChecker.check(code, [])
    end

    test "alias-tail collision does not unlock the real System module" do
      assert {:error, msg} =
               ASTChecker.check(~s|:"Elixir.System".cmd("id", [])|, [LegionToolset.System])

      assert msg =~ "System"
    end

    test "alias-tail collision does not unlock the real File module" do
      assert {:error, _} =
               ASTChecker.check(~s|:"Elixir.File".read!("/etc/passwd")|, [LegionToolset.File])
    end

    test "raise with a non-allowlisted module name is rejected" do
      assert {:error, _} = ASTChecker.check("raise NotInSandbox.Anything", [])
    end

    test "reraise with a non-allowlisted module name is rejected" do
      assert {:error, _} =
               ASTChecker.check("reraise NotInSandbox.Anything, [], []", [])
    end
  end

  describe "guards / when clauses" do
    test "when guard in fn is allowed" do
      assert :ok = ASTChecker.check("fn x when is_integer(x) -> x * 2 end", [])
    end

    test "when guard in case is allowed" do
      assert :ok = ASTChecker.check("case x do y when is_atom(y) -> :ok end", [])
    end

    test "multi-clause fn with when is allowed" do
      code = "fn x when is_integer(x) -> x; x when is_atom(x) -> :atom end"
      assert :ok = ASTChecker.check(code, [])
    end

    test "is_struct/2 guard with literal alias is allowed" do
      assert :ok = ASTChecker.check("fn x when is_struct(x, ArgumentError) -> :ok end", [])
    end
  end

  describe "struct literals" do
    test "%Date{} is allowed" do
      assert :ok =
               ASTChecker.check("%Date{year: 2024, month: 1, day: 1, calendar: Calendar.ISO}", [])
    end

    test "%MapSet{} is allowed" do
      assert :ok = ASTChecker.check("%MapSet{}", [])
    end

    test "stdlib exception struct is allowed" do
      assert :ok = ASTChecker.check(~s|%ArgumentError{message: "x"}|, [])
    end

    test "tool struct is allowed" do
      assert :ok = ASTChecker.check("%MyTool.Result{}", [MyTool.Result])
    end

    test "struct of unknown module is rejected" do
      assert {:error, msg} = ASTChecker.check("%Unknown.Mod{}", [])
      assert msg =~ "%Unknown.Mod{} is not allowed"
    end

    test "struct of File.Stream is rejected (not on safe list)" do
      assert {:error, msg} = ASTChecker.check("%File.Stream{}", [])
      assert msg =~ "%File.Stream{} is not allowed"
    end

    test "pattern-matching against safe struct is allowed" do
      code = "fn %Date{day: d} -> d end"
      assert :ok = ASTChecker.check(code, [])
    end

    test "struct in case branch is allowed" do
      code = "case x do %ArgumentError{} -> :err; _ -> :ok end"
      assert :ok = ASTChecker.check(code, [])
    end
  end

  describe "qualified Kernel forms" do
    test "Kernel.exit is allowed" do
      assert :ok = ASTChecker.check("Kernel.exit(:normal)", [])
    end

    test "Kernel.throw is allowed" do
      assert :ok = ASTChecker.check("Kernel.throw(:foo)", [])
    end

    test "Kernel.send is still rejected" do
      assert {:error, msg} = ASTChecker.check("Kernel.send(self(), :x)", [])
      assert msg =~ "Kernel.send is not allowed"
    end

    test "Kernel.spawn is still rejected" do
      assert {:error, msg} = ASTChecker.check("Kernel.spawn(fn -> :ok end)", [])
      assert msg =~ "Kernel.spawn is not allowed"
    end

    test "Kernel.apply is still rejected" do
      assert {:error, msg} = ASTChecker.check("Kernel.apply(Enum, :map, [[], &(&1)])", [])
      assert msg =~ "Kernel.apply is not allowed"
    end

    test "Kernel.raise is still rejected" do
      assert {:error, msg} = ASTChecker.check(~s|Kernel.raise("x")|, [])
      assert msg =~ "Kernel.raise is not allowed"
    end
  end

  describe "added stdlib allowances" do
    test "Map.values is allowed" do
      assert :ok = ASTChecker.check("Map.values(%{a: 1})", [])
    end

    test "JSON.decode! is allowed" do
      assert :ok = ASTChecker.check(~s|JSON.decode!("[1,2,3]")|, [])
    end

    test "JSON.encode! is allowed" do
      assert :ok = ASTChecker.check("JSON.encode!(%{a: 1})", [])
    end

    test "URI.parse is allowed" do
      assert :ok = ASTChecker.check(~s|URI.parse("https://example.com")|, [])
    end

    test "URI.encode is allowed" do
      assert :ok = ASTChecker.check(~s|URI.encode("hello world")|, [])
    end

    test "URI.default_port is rejected (mutation via /2 form)" do
      assert {:error, msg} = ASTChecker.check(~s|URI.default_port("http")|, [])
      assert msg =~ "URI.default_port is not allowed"
    end

    test ":erlang.float_to_binary is allowed" do
      assert :ok = ASTChecker.check(":erlang.float_to_binary(1.5, decimals: 2)", [])
    end

    test ":erlang.spawn is still rejected" do
      assert {:error, msg} = ASTChecker.check(":erlang.spawn(fn -> :ok end)", [])
      assert msg =~ ":erlang.spawn is not allowed"
    end
  end

  describe "improved error messages" do
    test "IO module hints to return values" do
      assert {:error, msg} = ASTChecker.check("IO.puts(\"x\")", [])
      assert msg =~ "return values"
    end

    test "dynamic dispatch hints to use Map.fetch!" do
      assert {:error, msg} = ASTChecker.check("user.name", [])
      assert msg =~ "Map.fetch!"
    end

    test "struct literal lists the safe modules" do
      assert {:error, msg} = ASTChecker.check("%Foo{}", [])
      assert msg =~ "Date"
      assert msg =~ "MapSet"
    end

    test "defmodule mentions anonymous functions" do
      assert {:error, msg} = ASTChecker.check("defmodule X do end", [])
      assert msg =~ "anonymous functions"
    end
  end
end
