defmodule Legion.Sandbox.Elixir.ASTChecker.RCEAttackVectorsTest do
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

  alias Legion.Sandbox.Elixir, as: Sandbox
  alias Legion.Sandbox.Elixir.ASTChecker

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
                 [Legion.Sandbox.Elixir.ASTChecker.RCEAttackVectorsTest.Tools.System]
               )

      assert msg =~ "Module System is not allowed"
    end

    test "rejects :\"Elixir.Code\".eval_string even when a tool's tail is Code" do
      assert {:error, msg} =
               Sandbox.execute(
                 ~s|:"Elixir.Code".eval_string("1 + 1")|,
                 5_000,
                 [Legion.Sandbox.Elixir.ASTChecker.RCEAttackVectorsTest.Tools.Code]
               )

      assert msg =~ "Module Code is not allowed"
    end

    test "rejects :\"Elixir.File\".read! even when a tool's tail is File" do
      assert {:error, msg} =
               Sandbox.execute(
                 ~s|:"Elixir.File".read!("/etc/hostname")|,
                 5_000,
                 [Legion.Sandbox.Elixir.ASTChecker.RCEAttackVectorsTest.Tools.File]
               )

      assert msg =~ "Module File is not allowed"
    end

    test "tail-alias matching still works for the legitimate alias form" do
      tool = Legion.Sandbox.Elixir.ASTChecker.RCEAttackVectorsTest.Tools.System

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
      # Two layers of defense both reject this:
      #   * the standalone bare-atom clause rejects `:asn1rt_nif` itself
      #     (NIF-loading erlang module atom in source), AND
      #   * the raise-with-non-literal-first-arg clause rejects `raise v`.
      # Either rejection satisfies the test; pin on whichever fires first.
      assert {:error, msg} = Sandbox.execute("v = :asn1rt_nif; raise v", 5_000, [])

      assert msg =~ "raise requires a literal exception module" or
               msg =~ "literal erlang-module atom :asn1rt_nif is not allowed"
    end

    test "rejects raise <variable> when value is not on the dangerous list" do
      # If the literal isn't one of the small denylist of NIF loaders, the
      # bare-atom clause doesn't fire — the raise-with-non-literal clause
      # is what protects us. This pins THAT path specifically.
      assert {:error, msg} = Sandbox.execute("v = :something_random; raise v", 5_000, [])
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

      # See `rejects raise <variable>` for the two-layers-of-defense rationale.
      assert msg =~ "reraise requires a literal exception module" or
               msg =~ "literal erlang-module atom :asn1rt_nif is not allowed"
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
      # The capture form alone is rejected even without the dangerous atom:
      assert {:error, msg} = ASTChecker.check("&raise/1", [])
      assert msg =~ "&raise/1 is not allowed"

      # Combined with a NIF atom, two clauses block it (whichever fires first):
      assert {:error, msg} =
               Sandbox.execute("(&raise/1).(:asn1rt_nif)", 5_000, [])

      assert msg =~ "&raise/1 is not allowed" or
               msg =~ "literal erlang-module atom :asn1rt_nif is not allowed"
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
      # Qualified-capture path is blocked outright:
      assert {:error, msg} = ASTChecker.check("&Kernel.raise/1", [])
      assert msg =~ "Kernel.raise is not allowed"

      # Combined with a NIF atom, two clauses block it (whichever fires first):
      assert {:error, msg} =
               Sandbox.execute("(&Kernel.raise/1).(:asn1rt_nif)", 5_000, [])

      assert msg =~ "Kernel.raise is not allowed" or
               msg =~ "literal erlang-module atom :asn1rt_nif is not allowed"
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

  describe "sigil_w / sigil_W with `a` modifier materialising atoms (FIXED)" do
    # The `a` modifier on `~w` / `~W` maps each split token through
    # `String.to_atom/1` at macro-expansion time (after the AST check). Two
    # related sandbox escapes were possible:
    #
    #   1. ARBITRARY MODULE ATOMS: `~w(Elixir.File.Stream)a` yields
    #      `:"Elixir.File.Stream"`, which combined with `Map.put` builds a
    #      fake `%File.Stream{}` and reaches arbitrary file write through
    #      `for ..., into: fake`.
    #   2. `:__struct__` ATOM via interpolation: the literal-binary
    #      substring guard for `"__struct__"` only inspects AST string
    #      literals; `~w(#{"_" <> "_str" <> "uct__"})a` builds the binary
    #      at runtime and `String.to_atom/1` materialises `:__struct__`,
    #      defeating the gate that protects every protocol-dispatch path.
    #
    # The fix is a dedicated `check_node` clause that:
    #   * REJECTS interpolated forms (`~w(#{x})a`) outright — runtime-built
    #     atoms are invisible to the static check.
    #   * For non-interpolated forms, rejects only the `"__struct__"` token.
    #     Other module-shaped tokens (`Elixir.System`, `asn1rt_nif`) yield
    #     inert atoms: the dot-call, struct-literal, and raise positions all
    #     require literal aliases / atom literals at AST-check time, and the
    #     calendar arity caps close the calendar-arg load primitive, so a
    #     runtime-materialised atom has nowhere dangerous to flow.
    #
    # Other modifiers (default string list, `s`, `c`) are unaffected.

    test "rejects ~w(_a __struct__)a (token __struct__)" do
      assert {:error, msg} =
               Sandbox.execute(~S[~w(_a __struct__)a] <> " |> List.last()", 5_000, [])

      assert msg =~ ~S|token "__struct__" is not allowed|
    end

    test "rejects ~W(_a __struct__)a (no-interp variant)" do
      assert {:error, msg} =
               Sandbox.execute(~S[~W(_a __struct__)a] <> " |> List.last()", 5_000, [])

      assert msg =~ ~S|token "__struct__" is not allowed|
    end

    test "rejects ~w(__struct__)a (single-token variant)" do
      assert {:error, msg} =
               Sandbox.execute(~S[~w(__struct__)a] <> " |> hd()", 5_000, [])

      assert msg =~ ~S|token "__struct__" is not allowed|
    end

    test "rejects interpolated ~w with `a` (defeats substring guard)" do
      code = ~S|s = "_" <> "_str" <> "uct__"; ~w(#{s})a|
      assert {:error, msg} = Sandbox.execute(code, 5_000, [])
      assert msg =~ "interpolation is not allowed"
    end

    test "rejects any interpolated ~w with `a`, even with safe-looking content" do
      # Interpolation defeats static inspection regardless of what the
      # interpolated value LOOKS like at parse time. This pins the
      # interpolation check rather than per-token classification.
      code = ~S|x = String.upcase("foo"); ~w(#{x})a|
      assert {:error, msg} = Sandbox.execute(code, 5_000, [])
      assert msg =~ "interpolation is not allowed"
    end

    test "rejects any binary literal containing __struct__" do
      # The substring guard on AST string literals is unchanged.
      assert {:error, msg} =
               Sandbox.execute(~s|"prefix __struct__ suffix"|, 5_000, [])

      assert msg =~ ~S|literal binary containing "__struct__"|
    end

    test "still allows ~w(foo bar baz) (default — string list)" do
      assert {:ok, {["foo", "bar", "baz"], _}} =
               Sandbox.execute("~w(foo bar baz)", 5_000, [])
    end

    test "still allows ~w(foo bar baz)s (explicit string list)" do
      assert {:ok, {["foo", "bar", "baz"], _}} =
               Sandbox.execute("~w(foo bar baz)s", 5_000, [])
    end

    test "still allows ~w(foo bar baz)c (charlist list)" do
      assert {:ok, {[~c"foo", ~c"bar", ~c"baz"], _}} =
               Sandbox.execute("~w(foo bar baz)c", 5_000, [])
    end

    test "still allows ~W(foo bar)s (uppercase no-interp variant)" do
      assert {:ok, {["foo", "bar"], _}} =
               Sandbox.execute("~W(foo bar)s", 5_000, [])
    end

    test "still allows ~w(red green blue)a (benign atom list, no interpolation)" do
      # The relaxed rule allows atom-list sigils as long as (a) there is no
      # interpolation and (b) every token is a benign atom (not `__struct__`,
      # not an unsafe Elixir-module atom, not a dangerous erlang-module atom).
      assert {:ok, {[:red, :green, :blue], _}} =
               Sandbox.execute("~w(red green blue)a", 5_000, [])
    end

    test "still allows ~W(ok error)a (uppercase atom-list, no interpolation)" do
      assert {:ok, {[:ok, :error], _}} =
               Sandbox.execute("~W(ok error)a", 5_000, [])
    end

    test "still allows ~w(microsecond second nanosecond)a (calendar-unit atoms)" do
      assert {:ok, {[:microsecond, :second, :nanosecond], _}} =
               Sandbox.execute("~w(microsecond second nanosecond)a", 5_000, [])
    end
  end

  describe "full sandbox escape via sigil-built :__struct__ + fake File.Stream (FIXED)" do
    # The end-to-end RCE that combined #1 and #2 above with `Map.put` and
    # `for ..., into:` to write arbitrary files.

    test "rejects the full file-write chain" do
      witness = "/tmp/legion_rce_witness_#{System.unique_integer([:positive])}"
      File.rm(witness)

      code = """
      s = "_" <> "_str" <> "uct__"
      [ss] = ~w(\#{s})a
      [fs] = ~w(Elixir.File.Stream)a
      fake = %{} |> Map.put(ss, fs)
                 |> Map.put(:path, "#{witness}")
                 |> Map.put(:modes, [:write])
                 |> Map.put(:line_or_bytes, :line)
                 |> Map.put(:raw, true)
                 |> Map.put(:node, :nonode@nohost)
      for c <- ["pwned\\n"], into: fake, do: c
      """

      assert {:error, _msg} = Sandbox.execute(code, 5_000, [])
      assert {:error, :enoent} = File.read(witness)
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

      assert msg =~ "force-loaded at runtime"
    end

    test "rejects DateTime.shift_zone with a non-safe TZ-DB literal" do
      assert {:error, msg} =
               Sandbox.execute(
                 ~s|DateTime.shift_zone(DateTime.utc_now(), "Europe/Warsaw", EvilTZ)|,
                 5_000,
                 []
               )

      assert msg =~ "force-loaded at runtime"
    end

    test "rejects Date.utc_today with non-safe calendar literal" do
      assert {:error, msg} =
               Sandbox.execute("Date.utc_today(EvilCal)", 5_000, [])

      assert msg =~ "force-loaded at runtime"
    end

    test "rejects atom-form calendar atom :\"Elixir.EvilCal\"" do
      assert {:error, msg} =
               Sandbox.execute(
                 ~s|Date.new(2026, 1, 1, :"Elixir.EvilCal")|,
                 5_000,
                 []
               )

      assert msg =~ "force-loaded at runtime"
    end

    test "rejects Date.new/4 even with Calendar.ISO (arity gate, not arg classification)" do
      assert {:error, msg} =
               Sandbox.execute("Date.new(2026, 1, 1, Calendar.ISO)", 5_000, [])

      assert msg =~ "Date.new/4 is not allowed"
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

    test "rejects erlang atom literal as calendar arg (Date.new with :asn1rt_nif)" do
      assert {:error, msg} = Sandbox.execute("Date.new(2026, 1, 1, :asn1rt_nif)", 5_000, [])
      assert msg =~ "force-loaded at runtime"
    end

    test "rejects erlang atom literal :erlang as calendar arg" do
      assert {:error, msg} = Sandbox.execute("Date.new(2026, 1, 1, :erlang)", 5_000, [])
      assert msg =~ "force-loaded at runtime"
    end

    test "rejects erlang atom literal :crypto as calendar arg" do
      assert {:error, msg} = Sandbox.execute("Date.new(2026, 1, 1, :crypto)", 5_000, [])
      assert msg =~ "force-loaded at runtime"
    end

    test "rejects atom-literal nested inside fn-call obfuscation" do
      # `(& &1).(:asn1rt_nif)` returns `:asn1rt_nif` at runtime; the literal
      # is in the arg subtree, recursive walker catches it.
      assert {:error, msg} =
               Sandbox.execute("Date.new(2026, 1, 1, (& &1).(:asn1rt_nif))", 5_000, [])

      assert msg =~ "force-loaded at runtime"
    end

    test "rejects atom literal nested in list/hd in calendar arg" do
      assert {:error, msg} =
               Sandbox.execute("Date.new(2026, 1, 1, hd([:asn1rt_nif]))", 5_000, [])

      assert msg =~ "force-loaded at runtime"
    end

    test "rejects literal alias nested in list in calendar arg" do
      assert {:error, msg} = Sandbox.execute("Date.new(2026, 1, 1, hd([ExUnit]))", 5_000, [])
      assert msg =~ "force-loaded at runtime"
    end

    test "rejects DateTime.from_iso8601 with erlang atom calendar" do
      assert {:error, msg} =
               Sandbox.execute(
                 ~s|DateTime.from_iso8601("2026-01-01T00:00:00Z", :asn1rt_nif)|,
                 5_000,
                 []
               )

      assert msg =~ "force-loaded at runtime"
    end

    test "rejects Calendar.compatible_calendars? entirely (both args are calendars)" do
      assert {:error, msg} =
               Sandbox.execute(
                 "Calendar.compatible_calendars?(Calendar.ISO, Calendar.ISO)",
                 5_000,
                 []
               )

      assert msg =~ "Calendar.compatible_calendars? is not allowed"
    end

    test "still allows Time.truncate with :microsecond unit (non-module atom)" do
      assert {:ok, {%Time{}, _}} =
               Sandbox.execute("Time.truncate(Time.utc_now(), :microsecond)", 5_000, [])
    end

    test "still allows DateTime.from_unix with :second unit" do
      assert {:ok, {{:ok, %DateTime{}}, _}} =
               Sandbox.execute("DateTime.from_unix(0, :second)", 5_000, [])
    end

    test "still allows Date.beginning_of_week with :default starting day" do
      assert {:ok, {%Date{}, _}} =
               Sandbox.execute("Date.beginning_of_week(~D[2026-01-15], :default)", 5_000, [])
    end

    test "still allows Date.day_of_week with :sunday starting day" do
      assert {:ok, {n, _}} =
               Sandbox.execute("Date.day_of_week(~D[2026-01-15], :sunday)", 5_000, [])

      assert is_integer(n)
    end

    test "still allows Calendar.strftime with atom-keyed opts" do
      # Keyword-list opts have atom keys (`:day_of_week_names`, etc.) that
      # are not module atoms; the recursive walk must accept them.
      code = ~s|Calendar.strftime(~D[2026-01-15], "%A")|
      assert {:ok, {bin, _}} = Sandbox.execute(code, 5_000, [])
      assert is_binary(bin)
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
        # A bare module alias as a value is now inert (no flow to a load
        # primitive). Using it via dynamic dispatch still gets rejected by
        # the dot-call clause.
        {"= match against module (atom inert)", ~s|x = Code|, [], :ok},
        {"= and then call", ~s|x = Code\nx.eval_string("1")|, [], :blocked},
        {"Module.concat literal", ~s|Module.concat([Code]).eval_string("1")|, [], :blocked},
        {"Function.identity then call", ~s|Function.identity(:os).cmd(~c"id")|, [], :blocked},
        {"variable named apply", ~s|apply = fn _ -> 1 end\napply.(1)|, [], :ok},
        {"elem then dot", ~s|elem({Code}, 0).eval_string("1")|, [], :blocked},
        {"map module then dot", ~s|m = Map.put(%{}, :k, Code); m.k.eval_string("1")|, [],
         :blocked},
        {"PID.send via var", ~s|p = self(); p.send(:hi)|, [], :blocked},
        {"erlang atom assigned then call", ~s|m = :erlang; m.halt()|, [], :blocked},
        {"map field access on var holding module then call",
         ~s|m = %{a: Code}; m.a.eval_string("1")|, [], :blocked},
        # The literal `Code` is now an inert value (no load-primitive flow).
        # `hd([Code])` materialises the atom `Code` but can't do anything
        # with it: dot-call / struct / raise positions reject non-literals.
        {"hd of [Code] returns module atom (allowed; atom inert)", ~s|hd([Code])|, [], :ok},
        {"erlang module-function tuple value (no call)", ~s|tuple = {:erlang, :halt}; tuple|, [],
         :ok},
        # The dynamic-dispatch clause still blocks `%m{}` regardless of `m`.
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
        # `Code` as a bare value is now inert (no load-primitive flow).
        {"bare module atom expression (atom inert)", ~s|Code|, [], :ok},
        {"bare atom in tuple (atom inert)", ~s|{Code, :eval_string, ["1"]}|, [], :ok},
        {"List.to_existing_atom via charlist", ~s|List.to_existing_atom(~c"erlang")|, [],
         :blocked},
        {"String.to_existing_atom Elixir.Code", ~s|String.to_existing_atom("Elixir.Code")|, [],
         :blocked},
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
        {"fake struct passed to inspect", ~s|inspect(%{__struct__: Code, foo: 1})|, [], :blocked},
        {"fake struct passed to to_string",
         ~s|to_string(%{__struct__: Version, major: 1, minor: 0, patch: 0, pre: [], build: nil})|,
         [], :blocked},
        {"fake struct via Map.put", ~s|m = Map.put(%{}, :__struct__, URI); inspect(m)|, [],
         :blocked},
        {"fake exception via raise of fake struct",
         ~s|raise %{__struct__: RuntimeError, __exception__: true, message: "boom"}|, [],
         :blocked},
        {"fake Range", ~s|inspect(%{__struct__: Range, first: 1, last: 10, step: 1})|, [],
         :blocked},
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
        {"in operator with fake Range", ~s|3 in %{__struct__: Range, first: 1, last: 5, step: 1}|,
         [], :blocked}
      ])
    end
  end

  describe "allowed-callback abuse and protocol gadgets" do
    test "behave as expected" do
      assert_outcomes([
        {"Enum.reduce malicious fn", ~s|Enum.reduce([1], 0, fn _, _ -> :erlang.halt() end)|, [],
         :blocked},
        {"Enum.map malicious fn", ~s|Enum.map([1], fn _ -> System.cmd("id", []) end)|, [],
         :blocked},
        {"Stream.unfold then run",
         "Stream.unfold(0, fn x -> {x, :erlang.halt()} end) |> Stream.run()", [], :blocked},
        {"Kernel.then with bad fn", ~s|then(1, fn _ -> :erlang.halt() end)|, [], :blocked},
        {"Kernel.tap with bad fn", ~s|tap(1, fn _ -> :erlang.halt() end)|, [], :blocked},
        {"pipe to apply", "[:erlang, :halt, []] |> apply()", [], :blocked},
        {"with else clause", ~s|with :nope <- :ok, do: :a, else: (_ -> :erlang.halt())|, [],
         :blocked},
        {"try after", ~s|try do :ok after :erlang.halt() end|, [], :blocked},
        {"for reduce", ~s|for x <- [1], reduce: 0 do _ -> :erlang.halt() end|, [], :blocked},
        {"fn IIFE", ~s|(fn -> :erlang.halt() end).()|, [], :blocked},
        {"Stream.iterate with bad fn but no run", ~s|Stream.iterate(0, fn x -> x + 1 end)|, [],
         :ok},
        {"fn returning module then dispatch", ~s|(fn -> :erlang end).().halt()|, [], :blocked},
        {"inspect a fn", ~s|inspect(fn -> 1 end)|, [], :ok},
        {"to_string self", ~s|to_string(self())|, [], :blocked}
      ])
    end
  end

  describe "literals: bitstrings, sigils, charlists, comprehensions" do
    test "behave as expected" do
      assert_outcomes([
        # Atom-list sigils with safe non-interpolated tokens are allowed
        # under the relaxed rule (the `a` modifier itself is not the threat;
        # interpolation and dangerous tokens are).
        {"sigil_w atoms benign tokens", ~s|~w(secret)a|, [], :ok},
        {"sigil_W atoms benign tokens", ~s|~W(secret)a|, [], :ok},
        # `__struct__` token is still blocked (sigil substring guard);
        # other module-shaped tokens are now inert atoms (no flow).
        {"sigil_w atoms with __struct__ token", ~s|~w(_a __struct__)a|, [], :blocked},
        {"sigil_w atoms with Elixir.System token (atom inert)", ~s|~w(Elixir.System)a|, [], :ok},
        {"sigil_w atoms with asn1rt_nif token (atom inert)", ~s|~w(asn1rt_nif)a|, [], :ok},
        {"sigil_w strings (default) still ok", ~s|~w(foo bar)|, [], :ok},
        {"sigil_w explicit string list still ok", ~s|~w(foo bar)s|, [], :ok},
        {"sigil_w charlist list still ok", ~s|~w(foo bar)c|, [], :ok},
        {"sigil_S string", ~s|~S"hello"|, [], :ok},
        {"binary type spec utf8", ~s|<<"id"::utf8>>|, [], :ok},
        {"binary size modifier", ~s|<<255::size(8)>>|, [], :ok},
        {"bitstring with custom unit", ~s|<<255::8-unit(1)>>|, [], :ok},
        {"charlist sigil_c", ~s|~c"id"|, [], :ok},
        {"to_charlist", ~s|to_charlist("id")|, [], :ok},
        {"for into %{}", ~s|for x <- [1], into: %{}, do: {x, x}|, [], :ok},
        {"for into ''", ~s|for x <- [1], into: "", do: <<x>>|, [], :ok},
        # The literal `Code` alias as a tuple element is just an inert
        # value — there's no AST-eval primitive in the sandbox so the
        # constructed "AST" is data, not executable.
        {"literal AST tuple with module alias (data only)",
         ~s|{{:., [], [Code, :eval_string]}, [], ["1"]}|, [], :ok},
        # The shape itself is fine when the alias slot is replaced with a
        # benign safe-listed module.
        {"literal AST tuple with safe alias", ~s|{{:., [], [Map, :get]}, [], [%{}, :k]}|, [], :ok}
      ])
    end
  end

  describe "tool-name tail-alias collisions" do
    test "all blocked" do
      assert_outcomes([
        {"tool collision: literal atom System call", ~s|:"Elixir.System".cmd("echo", ["pwned"])|,
         [Legion.Sandbox.Elixir.ASTChecker.RCEAttackVectorsTest.SystemTool], :blocked},
        {"tool collision: literal atom Code call",
         ~s|:"Elixir.Code".eval_string("System.cmd(\\"echo\\", [\\"pwned\\"]) ; 42")|,
         [Legion.Sandbox.Elixir.ASTChecker.RCEAttackVectorsTest.CodeTool], :blocked},
        {"tool sub-module dot",
         ~s|Legion.Sandbox.Elixir.ASTChecker.RCEAttackVectorsTest.SystemTool.System.cmd("id", [])|,
         [Legion.Sandbox.Elixir.ASTChecker.RCEAttackVectorsTest.SystemTool], :blocked},
        {"tool named SystemTool tail-collision via __struct__",
         ~s|%{__struct__: SystemTool, x: 1}|,
         [Legion.Sandbox.Elixir.ASTChecker.RCEAttackVectorsTest.SystemTool], :blocked},
        {"alias-tail RCE: literal :Elixir.System.cmd",
         ~s|:"Elixir.System".cmd("echo", ["pwned-by-rce"])|,
         [Legion.Sandbox.Elixir.ASTChecker.RCEAttackVectorsTest.Tools.System], :blocked},
        {"alias-tail RCE: literal :Elixir.Code.eval_string",
         ~s|:"Elixir.Code".eval_string("System.cmd(\\"echo\\", [\\"pwned\\"]) ; 7")|,
         [Legion.Sandbox.Elixir.ASTChecker.RCEAttackVectorsTest.Tools.Code], :blocked},
        {"alias-tail RCE: literal :Elixir.File.read", ~s|:"Elixir.File".read!("/etc/hostname")|,
         [Legion.Sandbox.Elixir.ASTChecker.RCEAttackVectorsTest.Tools.File], :blocked},
        {"alias-tail RCE via unaliased-form System.cmd (after alias prepend)",
         ~s|System.cmd("echo", ["fail"])|,
         [Legion.Sandbox.Elixir.ASTChecker.RCEAttackVectorsTest.Tools.System], :blocked}
      ])
    end
  end

  describe "literal module aliases as values are inert" do
    # Module-alias values (`Phoenix.LiveView`, `m = SomeMod`, ...) are
    # accepted: the AST check no longer has a load-primitive flow that an
    # atom value could reach. `raise`/struct-literal/dot-call positions all
    # require literal aliases at AST-check time and validate them; the
    # calendar-arg load primitive is closed by the arity gate. So an atom
    # in a value position has nowhere dangerous to flow.
    test "behave as expected" do
      assert_outcomes([
        {"unknown alias as tagged-tuple discriminator", ~s|{Phoenix.LiveView, :mount}|, [], :ok},
        {"ExUnit literal alias bound to variable", ~s|status = ExUnit; status|, [], :ok},
        {"Mix literal alias in list", ~s|[Mix, :env]|, [], :ok},
        {"unknown alias inside list nested in map value", ~s|%{kind: [Phoenix.Endpoint]}|, [],
         :ok},
        {"safe stdlib alias as tag", ~s|{Date, :today}|, [], :ok}
      ])
    end

    # The atom can flow nowhere dangerous, but if sandboxed code tries to
    # USE it as a load primitive (raise / struct-literal / dot-call), the
    # dedicated clauses still reject — non-literal first args / module slots
    # are denied regardless of what the variable holds.
    test "still blocked when used as a load primitive" do
      assert_outcomes([
        {"variable holding alias used as raise arg", ~s|m = ArgumentError; raise m|, [],
         :blocked},
        {"variable holding alias used as dot-call base", ~s|m = Date; m.utc_today()|, [],
         :blocked}
      ])
    end
  end
end
