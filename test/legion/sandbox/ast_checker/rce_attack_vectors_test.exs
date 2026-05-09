defmodule Legion.Sandbox.ASTChecker.RCEAttackVectorsTest do
  @moduledoc """
  RCE attack vectors against the AST checker.

  Two halves:

  - The "(FIXED)" describe blocks pin specific RCE classes that were once
    exploitable and have since been fixed. They assert on the exact rejection
    message and exist to catch regression.

  - The remaining describe blocks tag each candidate with an expected outcome
    (`:blocked` or `:ok`) and assert it. `:blocked` means the candidate must
    not pass the AST check and execute cleanly; any of `:ast_reject`, runtime
    error, or rescued/caught exit satisfies it. `:ok` means the candidate is
    a positive control that should pass the AST check and execute cleanly.
  """
  use ExUnit.Case, async: false

  alias Legion.Sandbox
  alias Legion.Sandbox.ASTChecker

  defmodule FakeTool do
    def hello, do: :hello
  end

  defmodule SystemTool do
    def hello, do: :hello
  end

  defmodule CodeTool do
    def hello, do: :hello
  end

  # The alias_tail of these modules collides with the GLOBAL System / Code /
  # File / IO / Process atoms. Passing one as a tool puts the global atom
  # (e.g. :"Elixir.System") into the tools allowlist!
  # Nested under .Tools to avoid shadowing the globals inside this test module.
  defmodule Tools.System do
    def hello, do: :ok
  end

  defmodule Tools.Code do
    def hello, do: :ok
  end

  defmodule Tools.File do
    def hello, do: :ok
  end

  defp run(code, tools) do
    case ASTChecker.check(code, tools) do
      :ok ->
        execution =
          try do
            Sandbox.execute(code, 5_000, tools)
          rescue
            e -> {:rescued, e}
          catch
            k, v -> {:caught, {k, v}}
          end

        {:ast_pass, execution}

      {:error, reason} ->
        {:ast_reject, reason}
    end
  end

  defp assert_outcomes(candidates) do
    for {name, code, tools, expected} <- candidates do
      result = run(code, tools)

      case expected do
        :blocked ->
          refute match?({:ast_pass, {:ok, _}}, result),
                 "[#{name}] expected to be blocked but executed cleanly\n" <>
                   "  code: #{String.replace(code, "\n", "\\n")}\n" <>
                   "  result: #{inspect(result, limit: :infinity, printable_limit: 300)}"

        :ok ->
          assert match?({:ast_pass, {:ok, _}}, result),
                 "[#{name}] expected to execute cleanly but was blocked\n" <>
                   "  code: #{String.replace(code, "\n", "\\n")}\n" <>
                   "  result: #{inspect(result, limit: :infinity, printable_limit: 300)}"
      end
    end
  end

  # ===========================================================================
  # Confirmed RCE classes (FIXED) - regression tests with explicit messages.
  # ===========================================================================

  describe "literal-atom call to a global with colliding tool tail (FIXED)" do
    test "rejects :\"Elixir.System\".cmd even when a tool's tail is System" do
      assert {:error, msg} =
               Sandbox.execute(
                 ~s|:"Elixir.System".cmd("printf", ["pwned"])|,
                 5_000,
                 [Legion.Sandbox.ASTChecker.RCEAttackVectorsTest.Tools.System]
               )

      assert msg =~ "Module System is not allowed"
    end

    test "rejects :\"Elixir.Code\".eval_string even when a tool's tail is Code" do
      assert {:error, msg} =
               Sandbox.execute(
                 ~s|:"Elixir.Code".eval_string("1 + 1")|,
                 5_000,
                 [Legion.Sandbox.ASTChecker.RCEAttackVectorsTest.Tools.Code]
               )

      assert msg =~ "Module Code is not allowed"
    end

    test "rejects :\"Elixir.File\".read! even when a tool's tail is File" do
      assert {:error, msg} =
               Sandbox.execute(
                 ~s|:"Elixir.File".read!("/etc/hostname")|,
                 5_000,
                 [Legion.Sandbox.ASTChecker.RCEAttackVectorsTest.Tools.File]
               )

      assert msg =~ "Module File is not allowed"
    end

    test "tail-alias matching still works for the legitimate alias form" do
      tool = Legion.Sandbox.ASTChecker.RCEAttackVectorsTest.Tools.System

      assert {:ok, {:ok, _}} =
               Sandbox.execute(~s|System.hello()|, 5_000, [tool])
    end
  end

  describe "fake struct via %{__struct__: ...} no longer reaches protocol implementations (FIXED)" do
    test "rejects %{__struct__: File.Stream, ...} map literal" do
      path =
        Path.join(
          System.tmp_dir!(),
          "legion-rce-#{System.unique_integer([:positive])}"
        )

      payload = "should-not-be-written-#{:rand.uniform(1_000_000_000)}\n"

      code = """
      fake = %{
        __struct__: File.Stream,
        path: path,
        modes: [:write],
        line_or_bytes: :line,
        raw: true,
        node: node()
      }

      for line <- [payload], into: fake, do: line
      """

      try do
        assert {:error, "literal :__struct__ atom is not allowed"} =
                 Sandbox.execute(code, 5_000, [], path: path, payload: payload)

        refute File.exists?(path)
      after
        File.rm(path)
      end
    end

    test "rejects Map.put(m, :__struct__, Mod) runtime construction" do
      assert {:error, "literal :__struct__ atom is not allowed"} =
               Sandbox.execute(
                 ~s|Map.put(%{}, :__struct__, File.Stream)|,
                 5_000,
                 []
               )
    end

    test "rejects Map.merge(m, %{__struct__: Mod}) runtime construction" do
      assert {:error, "literal :__struct__ atom is not allowed"} =
               Sandbox.execute(
                 ~s|Map.merge(%{}, %{__struct__: File.Stream})|,
                 5_000,
                 []
               )
    end

    test ~S|rejects literal "__struct__" string| do
      assert {:error, msg} = Sandbox.execute(~s|"__struct__"|, 5_000, [])
      assert msg =~ ~S|literal binary containing "__struct__"|
    end

    test "blocks String.to_existing_atom bypass by dropping it from allowlist" do
      assert {:error, msg} =
               Sandbox.execute(~s|String.to_existing_atom("foo")|, 5_000, [])

      assert msg =~ "String.to_existing_atom is not allowed"
    end

    test "blocks List.to_existing_atom bypass by dropping it from allowlist" do
      assert {:error, msg} =
               Sandbox.execute(~s|List.to_existing_atom(~c"foo")|, 5_000, [])

      assert msg =~ "List.to_existing_atom is not allowed"
    end

    test "control: the equivalent literal struct expression %File.Stream{...} is rejected" do
      code = """
      %File.Stream{path: "/tmp/x", modes: [:write], line_or_bytes: :line, raw: true, node: node()}
      """

      assert {:error, msg} = Sandbox.execute(code, 5_000, [])
      assert msg =~ "%File.Stream{} is not allowed"
    end

    test "control: a direct File.open call is rejected (File not in allowlist)" do
      assert {:error, msg} =
               Sandbox.execute(~s|File.open("/tmp/x", [:write])|, 5_000, [])

      assert msg =~ "Module File is not allowed"
    end

    test "control: a plain map literal without :__struct__ still works" do
      assert {:ok, {%{a: 1, b: 2}, _}} =
               Sandbox.execute(~s|%{a: 1, b: 2}|, 5_000, [])
    end
  end

  describe "raise/2 with arbitrary module (FIXED)" do
    test "rejects raise of a non-allowlisted module (alias form)" do
      assert {:error, msg} =
               Sandbox.execute(~s|raise Some.User.Module, message: "hi"|, 5_000, [])

      assert msg =~ "raise of"
      assert msg =~ "is not allowed"
    end

    test "rejects raise of a non-allowlisted module (atom form)" do
      assert {:error, msg} =
               Sandbox.execute(~s|raise :"Elixir.Some.User.Module", []|, 5_000, [])

      assert msg =~ "raise of"
      assert msg =~ "is not allowed"
    end

    test "rejects reraise of a non-allowlisted module" do
      assert {:error, msg} =
               Sandbox.execute(
                 ~s|reraise Some.User.Module, [message: "x"], []|,
                 5_000,
                 []
               )

      assert msg =~ "reraise of"
      assert msg =~ "is not allowed"
    end

    test "still allows raise of stdlib exceptions" do
      assert {:error, %RuntimeError{message: "boom"}} =
               Sandbox.execute(~s|raise RuntimeError, "boom"|, 5_000, [])

      assert {:error, %ArgumentError{}} =
               Sandbox.execute(~s|raise ArgumentError, "x"|, 5_000, [])
    end
  end

  describe "raise/reraise via dynamic / indirected first argument (FIXED)" do
    # The literal-only `raise Mod, ...` clauses fired only when the first
    # argument was an `__aliases__` literal or an atom literal. Wrapping the
    # module atom in any expression - variable, fn-call, list head, tuple
    # element, tool-fn return - bypassed the safe-exceptions allowlist and
    # let `Kernel.raise/2` force-load arbitrary modules at runtime
    # (triggering `@on_load` and `exception/1` side-effects).

    test "rejects raise <variable>" do
      assert {:error, msg} = Sandbox.execute("v = :asn1rt_nif; raise v", 5_000, [])
      assert msg =~ "raise requires a literal exception module"
    end

    test "rejects raise hd(list)" do
      assert {:error, msg} =
               Sandbox.execute("raise hd([Some.User.Module])", 5_000, [])

      assert msg =~ "raise requires a literal exception module"
    end

    test "rejects raise from fn return" do
      assert {:error, msg} =
               Sandbox.execute("raise (fn -> Some.Mod end).()", 5_000, [])

      assert msg =~ "raise requires a literal exception module"
    end

    test "rejects raise Map.get(...) result" do
      assert {:error, msg} =
               Sandbox.execute(
                 "raise Map.get(%{a: Some.Mod}, :a)",
                 5_000,
                 []
               )

      assert msg =~ "raise requires a literal exception module"
    end

    test "rejects reraise <variable>, [...], stacktrace" do
      assert {:error, msg} =
               Sandbox.execute(
                 "v = :asn1rt_nif; reraise v, [message: \"x\"], []",
                 5_000,
                 []
               )

      assert msg =~ "reraise requires a literal exception module"
    end

    test "still allows raise \"string\" (RuntimeError shorthand)" do
      assert {:error, %RuntimeError{message: "boom"}} =
               Sandbox.execute(~s|raise "boom"|, 5_000, [])
    end

    test "still allows raise \"interpolated #{}\"" do
      assert {:error, %RuntimeError{message: "x=42"}} =
               Sandbox.execute(~S|x = 42; raise "x=#{x}"|, 5_000, [])
    end
  end

  describe "raise/reraise capture (FIXED)" do
    # `&raise/n` and `&reraise/n` wrap `Kernel.raise` so the first argument is
    # supplied at runtime, completely bypassing the static safe-exceptions
    # gate. Verified to load `:asn1rt_nif` and run its NIF on_load before
    # the fix.

    test "rejects &raise/1" do
      assert {:error, msg} =
               Sandbox.execute("(&raise/1).(:asn1rt_nif)", 5_000, [])

      assert msg =~ "&raise/1 is not allowed"
    end

    test "rejects &raise/2" do
      assert {:error, msg} = ASTChecker.check("&raise/2", [])
      assert msg =~ "&raise/2 is not allowed"
    end

    test "rejects &reraise/2" do
      assert {:error, msg} = ASTChecker.check("&reraise/2", [])
      assert msg =~ "&reraise/2 is not allowed"
    end

    test "rejects &reraise/3" do
      assert {:error, msg} = ASTChecker.check("&reraise/3", [])
      assert msg =~ "&reraise/3 is not allowed"
    end

    test "rejects &Kernel.raise/1 (qualified capture)" do
      assert {:error, msg} =
               Sandbox.execute("(&Kernel.raise/1).(:asn1rt_nif)", 5_000, [])

      assert msg =~ "Kernel.raise is not allowed"
    end

    test "rejects &Kernel.reraise/2 (qualified capture)" do
      assert {:error, msg} =
               ASTChecker.check("&Kernel.reraise/2", [])

      assert msg =~ "Kernel.reraise is not allowed"
    end

    test "still allows &Map.get/2 (a non-raise capture)" do
      assert :ok = ASTChecker.check("&Map.get/2", [])
    end

    test "still allows &(&1 + 1)" do
      assert :ok = ASTChecker.check("&(&1 + 1)", [])
    end
  end

  describe "Map.keys / Map.to_list leak of :__struct__ (FIXED)" do
    # `Map.keys(struct)` returns `[:__struct__, ...]` directly, materialising
    # the literal atom that the static `:__struct__` rejection was meant to
    # prevent. Same for `Map.to_list/1` (returns `[{:__struct__, M}, ...]`).
    # Both removed from `@map_allowed`.

    test "Map.keys is rejected" do
      assert {:error, msg} = Sandbox.execute("Map.keys(1..3)", 5_000, [])
      assert msg =~ "Map.keys is not allowed"
    end

    test "Map.to_list is rejected" do
      assert {:error, msg} = Sandbox.execute("Map.to_list(1..3)", 5_000, [])
      assert msg =~ "Map.to_list is not allowed"
    end

    test "Map.from_struct is still allowed (it strips :__struct__)" do
      assert {:ok, {%{first: 1, last: 3, step: 1}, _}} =
               Sandbox.execute("Map.from_struct(1..3)", 5_000, [])
    end
  end

  describe "sigil_w / sigil_W with `a` modifier materialising :__struct__ (FIXED)" do
    # `~w(_a __struct__)a` parses to a sigil call whose literal argument is
    # a binary that *contains* "__struct__" but is not equal to it. The old
    # exact-equality check on the binary literal let it through. At
    # macro-expansion time (which `Code.eval_string` performs), `sigil_w`
    # with the `a` modifier maps tokens through `String.to_atom/1`, producing
    # the atom `:__struct__` despite both `String.to_atom` and the literal
    # atom being denied. Substring match closes every source-string path.

    test "rejects ~w(_a __struct__)a" do
      assert {:error, msg} =
               Sandbox.execute(~S[~w(_a __struct__)a] <> " |> List.last()", 5_000, [])

      assert msg =~ ~S|literal binary containing "__struct__"|
    end

    test "rejects ~W(_a __struct__)a (no-interp variant)" do
      assert {:error, msg} =
               Sandbox.execute(~S[~W(_a __struct__)a] <> " |> List.last()", 5_000, [])

      assert msg =~ ~S|literal binary containing "__struct__"|
    end

    test "rejects ~w(__struct__)a (single-token variant)" do
      assert {:error, msg} =
               Sandbox.execute(~S[~w(__struct__)a] <> " |> hd()", 5_000, [])

      assert msg =~ ~S|literal binary containing "__struct__"|
    end

    test "rejects any binary literal containing __struct__" do
      assert {:error, msg} =
               Sandbox.execute(~s|"prefix __struct__ suffix"|, 5_000, [])

      assert msg =~ ~S|literal binary containing "__struct__"|
    end

    test "still allows benign ~w / ~W sigils" do
      assert {:ok, {[:foo, :bar, :baz], _}} =
               Sandbox.execute("~w(foo bar baz)a", 5_000, [])
    end
  end

  describe "calendar-module argument loading (FIXED)" do
    # Date / DateTime / NaiveDateTime / Time / Calendar functions take a
    # `Calendar` (or time-zone-database) module argument that is dispatched
    # at runtime. `Date.new(2026, 1, 1, EvilCal)` triggered the BEAM module
    # loader to load `EvilCal`, running its `@on_load`. Conservative gate:
    # any literal alias / atom-literal in arg position to a calendar module
    # function must point at `Calendar.ISO`, `Calendar.UTCOnlyTimeZoneDatabase`,
    # another calendar module, or a tool module.

    test "rejects Date.new with a non-safe calendar literal" do
      assert {:error, msg} =
               Sandbox.execute(
                 "Date.new(2026, 1, 1, EvilCal)",
                 5_000,
                 []
               )

      assert msg =~ "passed to a calendar function would be dispatched"
    end

    test "rejects DateTime.shift_zone with a non-safe TZ-DB literal" do
      assert {:error, msg} =
               Sandbox.execute(
                 ~s|DateTime.shift_zone(DateTime.utc_now(), "Europe/Warsaw", EvilTZ)|,
                 5_000,
                 []
               )

      assert msg =~ "passed to a calendar function"
    end

    test "rejects Date.utc_today with non-safe calendar literal" do
      assert {:error, msg} =
               Sandbox.execute("Date.utc_today(EvilCal)", 5_000, [])

      assert msg =~ "passed to a calendar function"
    end

    test "rejects atom-form calendar atom :\"Elixir.EvilCal\"" do
      assert {:error, msg} =
               Sandbox.execute(
                 ~s|Date.new(2026, 1, 1, :"Elixir.EvilCal")|,
                 5_000,
                 []
               )

      assert msg =~ "passed to a calendar function"
    end

    test "still allows Date.new with Calendar.ISO" do
      assert {:ok, {{:ok, %Date{}}, _}} =
               Sandbox.execute("Date.new(2026, 1, 1, Calendar.ISO)", 5_000, [])
    end

    test "still allows Date.new with no calendar arg (default)" do
      assert {:ok, {{:ok, %Date{}}, _}} =
               Sandbox.execute("Date.new(2026, 1, 1)", 5_000, [])
    end

    test "still allows DateTime.utc_now()" do
      assert {:ok, {%DateTime{}, _}} =
               Sandbox.execute("DateTime.utc_now()", 5_000, [])
    end

    test "still allows DateTime.from_iso8601 with default" do
      assert {:ok, {{:ok, %DateTime{}, 0}, _}} =
               Sandbox.execute(
                 ~s|DateTime.from_iso8601("2026-01-01T00:00:00Z")|,
                 5_000,
                 []
               )
    end
  end

  describe "tool-tail collision with safe-exceptions allowlist (FIXED)" do
    # When a tool is named `Mallory.RuntimeError`, its tail alias `RuntimeError`
    # collides with the stdlib safe exception. After Sandbox.execute prepends
    # `alias Mallory.RuntimeError`, `raise RuntimeError, "x"` compiles to
    # `raise Mallory.RuntimeError, "x"`, calling the tool's `exception/1` and
    # force-loading the tool module — confused-deputy RCE if the tool author
    # is malicious. Same for any of the 19 entries in @safe_exceptions.

    defmodule Mallory.RuntimeError do
      defexception [:message]
    end

    defmodule Mallory.ArgumentError do
      defexception [:message]
    end

    test "rejects allowed_modules containing Mallory.RuntimeError" do
      assert {:error, msg} =
               ASTChecker.check(
                 ~s|raise RuntimeError, "x"|,
                 [Mallory.RuntimeError]
               )

      assert msg =~ "shadows stdlib safe-exception"
      assert msg =~ "Mallory.RuntimeError"
    end

    test "rejects allowed_modules containing Mallory.ArgumentError" do
      assert {:error, msg} = ASTChecker.check("1 + 1", [Mallory.ArgumentError])
      assert msg =~ "shadows stdlib safe-exception"
    end

    test "rejection happens before parse — no AST is walked" do
      # The collision check fires before Code.string_to_quoted, so even a
      # syntactically broken code string returns the collision error.
      assert {:error, msg} =
               ASTChecker.check("this is (((( not valid", [Mallory.RuntimeError])

      assert msg =~ "shadows stdlib safe-exception"
    end

    test "still allows tools whose tail does not collide" do
      assert :ok =
               ASTChecker.check(
                 ~s|raise RuntimeError, "x"|,
                 [Legion.Sandbox.ASTChecker.RCEAttackVectorsTest.FakeTool]
               )
    end
  end

  # ===========================================================================
  # Attack-vector batches.
  # ===========================================================================

  describe "direct calls to forbidden modules (sanity)" do
    test "all blocked" do
      assert_outcomes([
        {"direct System.cmd", ~s|System.cmd("id", [])|, [], :blocked},
        {"direct Code.eval_string", ~s|Code.eval_string("1")|, [], :blocked},
        {"direct :erlang.halt", ~s|:erlang.halt()|, [], :blocked},
        {"direct :os.cmd", ~s|:os.cmd(~c"id")|, [], :blocked},
        {"direct File.read", ~s|File.read("/etc/passwd")|, [], :blocked},
        {"direct Process.exit", ~s|Process.exit(self(), :kill)|, [], :blocked},
        {"direct apply/3", ~s|apply(:erlang, :halt, [])|, [], :blocked},
        {"Kernel.apply qualified", ~s|Kernel.apply(:erlang, :halt, [])|, [], :blocked},
        {"Process.send", ~s|Process.send(self(), :hi, [])|, [], :blocked},
        {"Process.put", ~s|Process.put(:k, Code)|, [], :blocked},
        {"Process.get", ~s|Process.get(:k)|, [], :blocked},
        {"IO.puts", ~s|IO.puts("hi")|, [], :blocked},
        {"Kernel.exit qualified", ~s|Kernel.exit(:normal)|, [], :blocked},
        {"Kernel.throw qualified", ~s|Kernel.throw(:hi)|, [], :blocked}
      ])
    end
  end

  describe "special forms and context macros" do
    test "all blocked" do
      assert_outcomes([
        {"__ENV__ no parens (variable form)", ~s|__ENV__|, [], :blocked},
        {"__MODULE__ no parens", ~s|__MODULE__|, [], :blocked},
        {"__CALLER__ no parens", ~s|__CALLER__|, [], :blocked},
        {"__DIR__ no parens", ~s|__DIR__|, [], :blocked},
        {"__STACKTRACE__ no parens", ~s|__STACKTRACE__|, [], :blocked},
        {"binding no parens", ~s|binding|, [], :blocked},
        {"binding parens", ~s|binding()|, [], :blocked},
        {"super no parens", ~s|super|, [], :blocked},
        {"var!", ~s|var!(x)|, [], :blocked},
        {"alias!", ~s|alias!(Foo)|, [], :blocked},
        {"@ operator", ~s|@something|, [], :blocked}
      ])
    end
  end

  describe "captures" do
    test "behave as expected" do
      assert_outcomes([
        {"capture &Code.eval_string/1", ~s|&Code.eval_string/1|, [], :blocked},
        {"capture &:erlang.halt/0", ~s|&:erlang.halt/0|, [], :blocked},
        {"capture invoke direct", ~s|(&:erlang.halt/0).()|, [], :blocked},
        {"capture &(System.cmd...)", ~s|(& System.cmd("id", [])).()|, [], :blocked},
        {"capture body &(&1.send/2)", ~s|(&(&1.send(self(), :hi))).(:erlang)|, [], :blocked},
        {"capture with no parens is checked", ~s|&Code.eval_string/1|, [], :blocked},
        {"f.() with captured allowed func", ~s|f = &Enum.sum/1; f.([1, 2, 3])|, [], :ok}
      ])
    end
  end

  describe "dynamic dispatch via variable / data" do
    test "behave as expected" do
      assert_outcomes([
        {"var = module then call", ~s|v = :erlang; v.halt()|, [], :blocked},
        {"head of list call", ~s|hd([:erlang]).halt()|, [], :blocked},
        {"hd().fun()", ~s|hd([Code]).eval_string("1")|, [], :blocked},
        {"= match against module", ~s|x = Code|, [], :ok},
        {"= and then call", ~s|x = Code\nx.eval_string("1")|, [], :blocked},
        {"Module.concat literal", ~s|Module.concat([Code]).eval_string("1")|, [], :blocked},
        {"Function.identity then call", ~s|Function.identity(:os).cmd(~c"id")|, [], :blocked},
        {"variable named apply", ~s|apply = fn _ -> 1 end\napply.(1)|, [], :ok},
        {"elem then dot", ~s|elem({Code}, 0).eval_string("1")|, [], :blocked},
        {"map module then dot",
         ~s|m = Map.put(%{}, :k, Code); m.k.eval_string("1")|, [], :blocked},
        {"PID.send via var", ~s|p = self(); p.send(:hi)|, [], :blocked},
        {"erlang atom assigned then call", ~s|m = :erlang; m.halt()|, [], :blocked},
        {"map field access on var holding module then call",
         ~s|m = %{a: Code}; m.a.eval_string("1")|, [], :blocked},
        {"hd of [Code] returns module atom", ~s|hd([Code])|, [], :ok},
        {"erlang module-function tuple value (no call)",
         ~s|tuple = {:erlang, :halt}; tuple|, [], :ok},
        {"struct head as variable", ~s|m = Code; %m{}|, [], :blocked}
      ])
    end
  end

  describe "atom-literal module dispatch" do
    test "behave as expected" do
      assert_outcomes([
        {"erlang via Elixir.alias atom", ~s|:"Elixir.Code".eval_string("1")|, [], :blocked},
        {"erlang as :erlang via call", ~s|:erlang.apply(:erlang, :halt, [])|, [], :blocked},
        {"erlang_apply via atom", ~s|:erlang.apply(:os, :cmd, [~c"id"])|, [], :blocked},
        {"alias.unquote(x)", ~s|Code.unquote(:eval_string)("1")|, [], :blocked},
        {"bare module atom expression", ~s|Code|, [], :ok},
        {"bare atom in tuple", ~s|{Code, :eval_string, ["1"]}|, [], :ok},
        {"List.to_existing_atom via charlist",
         ~s|List.to_existing_atom(~c"erlang")|, [], :blocked},
        {"String.to_existing_atom Elixir.Code",
         ~s|String.to_existing_atom("Elixir.Code")|, [], :blocked},
        {"String.to_existing_atom os", ~s|String.to_existing_atom("os")|, [], :blocked}
      ])
    end
  end

  describe "process and message primitives" do
    test "all blocked" do
      assert_outcomes([
        {"send bare", ~s|send(self(), :hi)|, [], :blocked},
        {"spawn bare", ~s|spawn(fn -> :ok end)|, [], :blocked},
        {"receive bare", ~s|receive do _ -> :ok end|, [], :blocked},
        {"Kernel.send qualified", ~s|Kernel.send(self(), :hi)|, [], :blocked},
        {"Kernel.spawn qualified", ~s|Kernel.spawn(fn -> :ok end)|, [], :blocked}
      ])
    end
  end

  describe "module loading and meta forms" do
    test "all blocked" do
      assert_outcomes([
        {"alias", ~s|alias System|, [], :blocked},
        {"import", ~s|import System|, [], :blocked},
        {"require", ~s|require Logger|, [], :blocked},
        {"use", ~s|use GenServer|, [], :blocked},
        {"quote do", ~s|quote do: :ok|, [], :blocked},
        {"unquote bare", ~s|unquote(:foo)|, [], :blocked},
        {"unquote_splicing bare", ~s|unquote_splicing([1])|, [], :blocked}
      ])
    end
  end

  describe "definition forms" do
    test "all blocked" do
      assert_outcomes([
        {"defmodule", ~s|defmodule Foo, do: nil|, [], :blocked},
        {"def in fn", ~s|fn -> def foo, do: 1 end|, [], :blocked},
        {"defstruct bare", ~s|defstruct foo: 1|, [], :blocked}
      ])
    end
  end

  describe "raise / reraise with arbitrary modules" do
    test "all blocked" do
      assert_outcomes([
        {"raise ArbitraryModule", ~s|raise SomeWeirdModule|, [], :blocked},
        {"raise :erlang", ~s|raise :erlang|, [], :blocked},
        {"raise Code, []", ~s|raise Code, []|, [], :blocked},
        {"raise fake RuntimeError exception",
         ~s|raise %{__struct__: RuntimeError, __exception__: true, message: "boom"}|, [],
         :blocked},
        {"raise fake ArgumentError exception",
         ~s|raise %{__struct__: ArgumentError, __exception__: true, message: "boom"}|, [],
         :blocked}
      ])
    end
  end

  describe "fake structs via %{__struct__: ...}" do
    test "all blocked" do
      assert_outcomes([
        {"%{} map with __struct__ key", ~s|%{__struct__: URI, host: "x"}|, [], :blocked},
        {"fake URI struct", ~s|%{__struct__: URI, host: "x"}|, [], :blocked},
        {"fake struct passed to inspect",
         ~s|inspect(%{__struct__: Code, foo: 1})|, [], :blocked},
        {"fake struct passed to to_string",
         ~s|to_string(%{__struct__: Version, major: 1, minor: 0, patch: 0, pre: [], build: nil})|,
         [], :blocked},
        {"fake struct via Map.put",
         ~s|m = Map.put(%{}, :__struct__, URI); inspect(m)|, [], :blocked},
        {"fake exception via raise of fake struct",
         ~s|raise %{__struct__: RuntimeError, __exception__: true, message: "boom"}|, [],
         :blocked},
        {"fake Range",
         ~s|inspect(%{__struct__: Range, first: 1, last: 10, step: 1})|, [], :blocked},
        {"for into fake MapSet",
         ~s|for x <- [1, 2], into: %{__struct__: MapSet, map: %{}, version: 2}, do: x|, [],
         :blocked},
        {"Enum.to_list on fake Range",
         ~s|Enum.to_list(%{__struct__: Range, first: 1, last: 3, step: 1})|, [], :blocked},
        {"Enum.reduce on fake MapSet",
         "Enum.reduce(%{__struct__: MapSet, map: %{a: [], b: []}, version: 2}, [], fn x, acc -> [x | acc] end)",
         [], :blocked},
        {"Enum.count on fake Date.Range",
         ~s|Enum.count(%{__struct__: Date.Range, first: ~D[2026-01-01], last: ~D[2026-01-05], first_in_iso_days: 0, last_in_iso_days: 0, step: 1})|,
         [], :blocked},
        {"Enum.into to_string with fake Version",
         ~s|to_string(%{__struct__: Version, major: 9, minor: 9, patch: 9, pre: [\"a\"], build: \"b\"})|,
         [], :blocked},
        {"match fake Range",
         ~s|case %{__struct__: Range, first: 1, last: 5, step: 1} do %Range{} = r -> Enum.to_list(r); _ -> :no end|,
         [], :blocked},
        {"inspect a fake Inspect.Opts",
         ~s|inspect(%{__struct__: Inspect.Opts, base: :decimal, binaries: :infer, char_lists: :infer, charlists: :infer, custom_options: [], inspect_fun: fn _, _ -> :ok end, limit: 50, pretty: true, printable_limit: 4096, safe: true, structs: true, syntax_colors: [], width: 80})|,
         [], :blocked},
        {"in operator with fake Range",
         ~s|3 in %{__struct__: Range, first: 1, last: 5, step: 1}|, [], :blocked}
      ])
    end
  end

  describe "allowed-callback abuse and protocol gadgets" do
    test "behave as expected" do
      assert_outcomes([
        {"Enum.reduce malicious fn",
         ~s|Enum.reduce([1], 0, fn _, _ -> :erlang.halt() end)|, [], :blocked},
        {"Enum.map malicious fn",
         ~s|Enum.map([1], fn _ -> System.cmd("id", []) end)|, [], :blocked},
        {"Stream.unfold then run",
         "Stream.unfold(0, fn x -> {x, :erlang.halt()} end) |> Stream.run()", [], :blocked},
        {"Kernel.then with bad fn", ~s|then(1, fn _ -> :erlang.halt() end)|, [], :blocked},
        {"Kernel.tap with bad fn", ~s|tap(1, fn _ -> :erlang.halt() end)|, [], :blocked},
        {"pipe to apply", "[:erlang, :halt, []] |> apply()", [], :blocked},
        {"with else clause",
         ~s|with :nope <- :ok, do: :a, else: (_ -> :erlang.halt())|, [], :blocked},
        {"try after", ~s|try do :ok after :erlang.halt() end|, [], :blocked},
        {"for reduce", ~s|for x <- [1], reduce: 0 do _ -> :erlang.halt() end|, [], :blocked},
        {"fn IIFE", ~s|(fn -> :erlang.halt() end).()|, [], :blocked},
        {"Stream.iterate with bad fn but no run",
         ~s|Stream.iterate(0, fn x -> x + 1 end)|, [], :ok},
        {"fn returning module then dispatch",
         ~s|(fn -> :erlang end).().halt()|, [], :blocked},
        {"inspect a fn", ~s|inspect(fn -> 1 end)|, [], :ok},
        {"to_string self", ~s|to_string(self())|, [], :blocked}
      ])
    end
  end

  describe "literals: bitstrings, sigils, charlists, comprehensions" do
    test "behave as expected" do
      assert_outcomes([
        {"sigil_W atoms", ~s|~w(secret)a|, [], :ok},
        {"sigil_S string", ~s|~S"hello"|, [], :ok},
        {"binary type spec utf8", ~s|<<"id"::utf8>>|, [], :ok},
        {"binary size modifier", ~s|<<255::size(8)>>|, [], :blocked},
        {"bitstring with custom unit", ~s|<<255::8-unit(1)>>|, [], :blocked},
        {"charlist sigil_c", ~s|~c"id"|, [], :ok},
        {"to_charlist", ~s|to_charlist("id")|, [], :ok},
        {"for into %{}", ~s|for x <- [1], into: %{}, do: {x, x}|, [], :ok},
        {"for into ''", ~s|for x <- [1], into: "", do: <<x>>|, [], :ok},
        {"literal AST tuple",
         ~s|{{:., [], [Code, :eval_string]}, [], ["1"]}|, [], :ok}
      ])
    end
  end

  describe "tool-name tail-alias collisions" do
    test "all blocked" do
      assert_outcomes([
        {"tool collision: literal atom System call",
         ~s|:"Elixir.System".cmd("echo", ["pwned"])|,
         [Legion.Sandbox.ASTChecker.RCEAttackVectorsTest.SystemTool], :blocked},
        {"tool collision: literal atom Code call",
         ~s|:"Elixir.Code".eval_string("System.cmd(\\"echo\\", [\\"pwned\\"]) ; 42")|,
         [Legion.Sandbox.ASTChecker.RCEAttackVectorsTest.CodeTool], :blocked},
        {"tool sub-module dot",
         ~s|Legion.Sandbox.ASTChecker.RCEAttackVectorsTest.SystemTool.System.cmd("id", [])|,
         [Legion.Sandbox.ASTChecker.RCEAttackVectorsTest.SystemTool], :blocked},
        {"tool named SystemTool tail-collision via __struct__",
         ~s|%{__struct__: SystemTool, x: 1}|,
         [Legion.Sandbox.ASTChecker.RCEAttackVectorsTest.SystemTool], :blocked},
        {"alias-tail RCE: literal :Elixir.System.cmd",
         ~s|:"Elixir.System".cmd("echo", ["pwned-by-rce"])|,
         [Legion.Sandbox.ASTChecker.RCEAttackVectorsTest.Tools.System], :blocked},
        {"alias-tail RCE: literal :Elixir.Code.eval_string",
         ~s|:"Elixir.Code".eval_string("System.cmd(\\"echo\\", [\\"pwned\\"]) ; 7")|,
         [Legion.Sandbox.ASTChecker.RCEAttackVectorsTest.Tools.Code], :blocked},
        {"alias-tail RCE: literal :Elixir.File.read",
         ~s|:"Elixir.File".read!("/etc/hostname")|,
         [Legion.Sandbox.ASTChecker.RCEAttackVectorsTest.Tools.File], :blocked},
        {"alias-tail RCE via unaliased-form System.cmd (after alias prepend)",
         ~s|System.cmd("echo", ["fail"])|,
         [Legion.Sandbox.ASTChecker.RCEAttackVectorsTest.Tools.System], :blocked}
      ])
    end
  end
end
