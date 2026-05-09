defmodule Legion.Sandbox.ASTChecker do
  @moduledoc """
  Static safety check for sandboxed code.

  Parses a code string into an AST and walks every node, rejecting the first
  violation found. The check is **default-deny** for built-in modules: every
  module/function call must be explicitly listed.

  Three categories are validated:

  - **Bare forms** - things written without a module prefix (`if`, `case`, `+`,
    `fn`, `<<>>`, `is_atom`, `raise`, `to_string`, ...) must be in
    `@allowed_bare_forms`. Anything else (`def`, `defstruct`, `__MODULE__`,
    `apply`, `spawn`, `send`, `receive`, ...) is rejected.
  - **`Module.function/n` calls** - the module must be either built-in
    (and the function must appear in that module's allowlist) or supplied by
    the caller in `allowed_modules`. Caller-supplied modules are treated as
    *tools* and any function on them is allowed. Tail aliases (`Helper` for
    `MyApp.Helper`) are recognised only for `__aliases__` AST nodes, never
    for atom-literal module dispatch (`:"Elixir.Helper".fun(...)`), to prevent
    a tail collision (e.g. tool `MyApp.System`) from unlocking the real
    stdlib module.
  - **Dynamic dispatch** - any `expr.fun` form (with or without parens, with
    or without args) where the dot's base is not a literal module is rejected.
    This includes `m.key` map field access: at AST time we cannot distinguish
    map field access from a 0-arity call on an atom-valued variable, and the
    runtime resolves `atom.fun` as `atom.fun()`. Use `m[:key]` (Access protocol)
    or `Map.fetch!(m, :key)` for map field access.
  - **`raise` / `reraise`** - the module argument (if any) must be in a small
    allowlist of safe stdlib exceptions; otherwise raise resolves and loads
    arbitrary modules at runtime via `Mod.exception/1`.
  - **Fake structs** - the literal atom `:__struct__` and the literal string
    `"__struct__"` are rejected. A map with an `__struct__` key is treated as
    a struct by every protocol in the BEAM, and the map literal `:%{}` form
    sidesteps the `:%` struct-form check.

  Built-in modules and their allowed functions are defined in this file.
  Functions that can break out of the sandbox (atom-table churn, dynamic code
  evaluation, code definition, process / message manipulation, time-zone DB
  mutation, ...) are simply not in any allowlist.

  ## Known limitations

  The check focuses on RCE prevention. It does **not** protect against:

  - Atom-table growth from parsing the code itself: `Code.string_to_quoted/1`
    creates atoms for every identifier (variable name, function name, module
    alias, atom literal) it sees in the source. A pathological input with
    many unique identifiers will inflate the atom table even when every call
    site is denied.
  - Most denial-of-service vectors (CPU, memory, message queue depth,
    long-running comprehensions, ...). Wallclock timeouts in
    `Legion.Sandbox.execute/4` are the only mitigation.
  """

  # ---------------------------------------------------------------------------
  # Bare forms
  # ---------------------------------------------------------------------------
  # Every non-prefixed call/identifier in user code resolves to one of these.
  # Anything outside this set is rejected. In particular: `def`, `defp`,
  # `defmodule`, `defmacro`, `defmacrop`, `defprotocol`, `defstruct`,
  # `defexception`, `defguard`, `defguardp`, `defdelegate`, `defoverridable`,
  # `defimpl`, `alias`, `import`, `require`, `use`, `quote`, `unquote`,
  # `unquote_splicing`, `apply`, `spawn`, `spawn_link`, `spawn_monitor`, `send`,
  # `receive`, `__ENV__`, `__MODULE__`, `__CALLER__`, `__DIR__`,
  # `__STACKTRACE__`, `binding`, `var!`, `alias!`, `dbg`, `super`.

  @allowed_special_forms ~w(
    __aliases__ __block__ -> <- |
    {} %{} <<>>
    fn case cond if unless for with try
    = ^ :: ..  ..// &
  )a

  @allowed_kernel_operators ~w(
    + - * / ** ++ -- <> == != === !== =~ < > <= >= && || ! and or not in |> @
  )a

  @allowed_kernel_guards ~w(
    is_atom is_binary is_bitstring is_boolean is_exception is_float
    is_function is_integer is_list is_map is_map_key is_nil is_non_struct_map
    is_number is_pid is_port is_reference is_struct is_tuple
  )a

  @allowed_kernel_macros_and_funs ~w(
    abs binary_part binary_slice bit_size byte_size ceil div elem floor
    get_and_update_in get_in hd inspect length make_ref map_size max min
    pop_in put_elem put_in rem round self tap then tl to_charlist
    to_string to_timeout trunc tuple_size update_in
    raise reraise throw exit
    match? if unless tap then
    sigil_C sigil_D sigil_N sigil_R sigil_S sigil_T sigil_U
    sigil_c sigil_r sigil_s sigil_w sigil_W
  )a

  @allowed_bare_forms MapSet.new(
                       @allowed_special_forms ++
                         @allowed_kernel_operators ++
                         @allowed_kernel_guards ++
                         @allowed_kernel_macros_and_funs
                     )

  # ---------------------------------------------------------------------------
  # Built-in modules with per-function allowlists
  # ---------------------------------------------------------------------------

  # Kernel: only the safe pieces. Notably absent: spawn*, send, receive, exit,
  # apply, def*, binary_to_atom, list_to_atom, binary_to_existing_atom,
  # list_to_existing_atom, function_exported?, macro_exported?, var!, alias!,
  # binding, dbg, use, to_char_list (deprecated), spawn_request, throw,
  # node (would let sandboxed code learn the BEAM node atom needed to
  # construct a valid `%File.Stream{}` field-set on distributed VMs).
  # `exit/throw` are reachable as bare forms but blocked when explicitly
  # qualified as `Kernel.exit` / `Kernel.throw` to mirror the historical policy.
  # `raise`/`reraise` are also intentionally absent: they are reachable only
  # as bare forms, gated by the dedicated `:raise`/`:reraise` clauses below
  # (which validate the exception module against `@safe_exceptions`).
  # Allowing `Kernel.raise` would defeat the gate, both as a direct call
  # (`Kernel.raise(EvilMod)`) and as a capture (`&Kernel.raise/1`), because
  # neither path goes through the `:raise` clauses.
  @kernel_allowed ~w(
    abs binary_part binary_slice bit_size byte_size ceil div elem floor
    get_and_update_in get_in hd inspect length make_ref map_size max min
    pop_in put_elem put_in rem round self tap then tl
    to_charlist to_string to_timeout trunc tuple_size update_in
    match? if unless in tap then
    is_atom is_binary is_bitstring is_boolean is_exception is_float
    is_function is_integer is_list is_map is_map_key is_nil is_non_struct_map
    is_number is_pid is_port is_reference is_struct is_tuple
    + - * / ** ++ -- <> == != === !== =~ < > <= >= && || ! and or not |>
    sigil_C sigil_D sigil_N sigil_R sigil_S sigil_T sigil_U
    sigil_c sigil_r sigil_s sigil_w sigil_W
  )a

  @string_allowed ~w(
    at bag_distance byte_slice capitalize chunk codepoints contains?
    count downcase duplicate ends_with? equivalent? first graphemes
    jaro_distance last length match? myers_difference next_codepoint
    next_grapheme next_grapheme_size normalize pad_leading pad_trailing
    printable? replace replace_invalid replace_leading replace_prefix
    replace_suffix replace_trailing reverse slice split split_at splitter
    starts_with? to_charlist to_float to_integer trim
    trim_leading trim_trailing upcase valid? valid_character?
  )a

  @enum_allowed ~w(
    all? any? at chunk_by chunk_every chunk_while concat count count_until
    dedup dedup_by drop drop_every drop_while each empty? fetch fetch! filter
    find find_index find_value flat_map flat_map_reduce frequencies
    frequencies_by group_by intersperse into join map map_every
    map_intersperse map_join map_reduce max max_by member? min min_by
    min_max min_max_by partition product product_by random reduce reduce_while
    reject reverse reverse_slice scan shuffle slice slide sort sort_by split
    split_while split_with sum sum_by take take_every take_random take_while
    to_list uniq uniq_by unzip with_index zip zip_reduce zip_with
  )a

  # Map: `keys` and `to_list` are deliberately absent. Both leak the literal
  # atom `:__struct__` from any struct value (`Map.keys(1..3)` returns
  # `[:__struct__, :first, :last, :step]`). With `:__struct__` in hand,
  # sandboxed code can build `Map.put(map, atom, EvilMod)` and route the
  # resulting fake-struct through any protocol (Collectable, Inspect,
  # String.Chars, Enumerable), reaching arbitrary stdlib impls — most
  # directly, `%File.Stream{}` via `for ..., into: fake` to write files.
  # `from_struct/1` is kept (it strips `:__struct__`).
  @map_allowed ~w(
    delete drop equal? fetch fetch! filter from_keys from_struct get
    get_and_update get_and_update! get_lazy has_key? intersect map merge
    new pop pop! pop_lazy put put_new put_new_lazy reject replace replace!
    replace_lazy size split split_with take update update!
  )a

  @mapset_allowed ~w(
    delete difference disjoint? equal? filter intersection member? new put
    reject size split_with subset? symmetric_difference to_list union
  )a

  # List: to_atom and to_existing_atom are both omitted. to_existing_atom looks
  # innocuous but lets sandboxed code reconstruct any already-loaded atom from
  # bytewise-built input (`'_' ++ '_struct__'` etc.), defeating the static
  # rejection of the literal `:__struct__` token used to gate fake-struct
  # protocol-dispatch attacks.
  @list_allowed ~w(
    ascii_printable? delete delete_at duplicate ends_with? first flatten foldl
    foldr improper? insert_at keydelete keyfind keyfind! keymember? keyreplace
    keysort keystore keytake last myers_difference pop_at replace_at
    starts_with? to_charlist to_float to_integer to_string
    to_tuple update_at wrap zip
  )a

  @keyword_allowed ~w(
    delete delete_first drop equal? fetch fetch! filter from_keys get
    get_and_update get_and_update! get_lazy get_values has_key? intersect
    keys keyword? map merge new pop pop! pop_first pop_lazy pop_values put
    put_new put_new_lazy reject replace replace! replace_lazy size split
    split_with take to_list update update! validate validate! values
  )a

  @tuple_allowed ~w(append delete_at duplicate insert_at product sum to_list)a

  @integer_allowed ~w(
    digits extended_gcd floor_div gcd is_even is_odd mod parse pow to_charlist
    to_string undigits
  )a

  @float_allowed ~w(
    ceil floor max_finite min_finite parse pow ratio round to_charlist to_string
  )a

  # Atom: only conversions away from atoms. No to_atom variants exist on Atom
  # itself, but be explicit.
  @atom_allowed ~w(to_charlist to_string)a

  # Regex.compile / Regex.compile! are allowed: the regex engine is bounded.
  @regex_allowed ~w(
    compile compile! escape match? named_captures names opts re_pattern
    recompile recompile! regex? replace run scan source split version
  )a

  @range_allowed ~w(disjoint? new range? shift size split to_list)a

  @access_allowed ~w(all at at! elem fetch fetch! filter find get get_and_update
                     key key! pop slice values)a

  @stream_allowed ~w(
    chunk_by chunk_every chunk_while concat cycle dedup dedup_by drop
    drop_every drop_while duplicate each filter flat_map from_index
    intersperse interval into iterate map map_every reject repeatedly
    resource run scan take take_every take_while timer transform unfold
    uniq uniq_by with_index zip zip_with
  )a

  @date_allowed ~w(
    add after? before? beginning_of_month beginning_of_week compare convert
    convert! day_of_era day_of_week day_of_year days_in_month diff
    end_of_month end_of_week from_erl from_erl! from_gregorian_days
    from_iso8601 from_iso8601! leap_year? months_in_year new new!
    quarter_of_year range shift to_erl to_gregorian_days to_iso8601
    to_iso_days to_string utc_today year_of_era
  )a

  @datetime_allowed ~w(
    add after? before? compare convert convert! diff from_gregorian_seconds
    from_iso8601 from_naive from_naive! from_unix from_unix! new new! now
    now! shift shift_zone shift_zone! to_date to_gregorian_seconds to_iso8601
    to_naive to_string to_time to_unix truncate utc_now
  )a

  @naive_datetime_allowed ~w(
    add after? before? beginning_of_day compare convert convert! diff
    end_of_day from_erl from_erl! from_gregorian_seconds from_iso8601
    from_iso8601! local_now new new! shift to_date to_erl
    to_gregorian_seconds to_iso8601 to_string to_time truncate utc_now
  )a

  @time_allowed ~w(
    add after? before? compare convert convert! diff from_erl from_erl!
    from_iso8601 from_iso8601! from_seconds_after_midnight new new! shift
    to_erl to_iso8601 to_seconds_after_midnight to_string truncate utc_now
  )a

  # Calendar: only the read-only side. put_time_zone_database mutates global env.
  @calendar_allowed ~w(
    compatible_calendars? get_time_zone_database strftime truncate
  )a

  @math_allowed ~w(
    acos acosh asin asinh atan atan2 atanh ceil cos cosh erf erfc exp floor
    fmod log log10 log2 pi pow sin sinh sqrt tan tanh tau
  )a

  # Modules whose functions accept a `Calendar` or time-zone-database module
  # argument that is dispatched at runtime (`module_arg.day_of_week/3`,
  # `module_arg.time_zone_period_from_utc_iso_days/2`, ...). The runtime
  # dispatch loads the named module and runs its `@on_load`, so any literal
  # alias / atom-literal module reference appearing as an argument to a
  # function on one of these modules must point at a known-safe calendar
  # module (`@safe_calendar_modules`) or at a tool module.
  @calendar_modules MapSet.new([
                      Date,
                      DateTime,
                      NaiveDateTime,
                      Time,
                      Calendar
                    ])

  @safe_calendar_modules MapSet.new([
                           Calendar.ISO,
                           Calendar.UTCOnlyTimeZoneDatabase
                         ])

  # Stdlib exception modules safe to use as the first argument to `raise`/`reraise`.
  # Anything outside this set forces `Mod.exception/1` at runtime, which loads
  # the named module and runs its `@on_load`.
  @safe_exceptions MapSet.new([
                     ArgumentError,
                     ArithmeticError,
                     BadArityError,
                     BadBooleanError,
                     BadFunctionError,
                     BadMapError,
                     BadStructError,
                     CaseClauseError,
                     CondClauseError,
                     ErlangError,
                     FunctionClauseError,
                     KeyError,
                     MatchError,
                     Protocol.UndefinedError,
                     RuntimeError,
                     SystemLimitError,
                     TryClauseError,
                     UndefinedFunctionError,
                     WithClauseError
                   ])

  @builtin_module_functions %{
    Kernel => MapSet.new(@kernel_allowed),
    String => MapSet.new(@string_allowed),
    Enum => MapSet.new(@enum_allowed),
    Map => MapSet.new(@map_allowed),
    MapSet => MapSet.new(@mapset_allowed),
    List => MapSet.new(@list_allowed),
    Keyword => MapSet.new(@keyword_allowed),
    Tuple => MapSet.new(@tuple_allowed),
    Integer => MapSet.new(@integer_allowed),
    Float => MapSet.new(@float_allowed),
    Atom => MapSet.new(@atom_allowed),
    Regex => MapSet.new(@regex_allowed),
    Range => MapSet.new(@range_allowed),
    Access => MapSet.new(@access_allowed),
    Stream => MapSet.new(@stream_allowed),
    Date => MapSet.new(@date_allowed),
    DateTime => MapSet.new(@datetime_allowed),
    NaiveDateTime => MapSet.new(@naive_datetime_allowed),
    Time => MapSet.new(@time_allowed),
    Calendar => MapSet.new(@calendar_allowed),
    :math => MapSet.new(@math_allowed)
  }

  @max_code_size 64 * 1024

  @doc """
  Validates `code_string` against the safety rules.

  `allowed_modules` are caller-supplied tool modules. They are trusted: any
  function on them may be called. Both fully-qualified names (`MyApp.Helper`)
  and their tail aliases (`Helper`) are recognised, so code written without
  aliases will still pass validation before `Legion.Sandbox` prepends them.

  Must be called **before** alias prepending - `alias` itself is rejected.

  Returns `:ok` or `{:error, reason}` on the first violation (or parse error).
  """
  def check(code_string, _allowed_modules)
      when byte_size(code_string) > @max_code_size do
    {:error, "code exceeds maximum size of #{@max_code_size} bytes"}
  end

  def check(code_string, allowed_modules) do
    with :ok <- check_tool_collisions(allowed_modules) do
      case Code.string_to_quoted(code_string) do
        {:ok, ast} ->
          tools = {
            MapSet.new(allowed_modules),
            MapSet.new(Enum.map(allowed_modules, &alias_tail/1))
          }

          {_ast, result} = Macro.prewalk(ast, :ok, &check_node(&1, &2, tools))

          result

        {:error, {_meta, message, token}} ->
          {:error, "Parse error: #{message}#{token}"}
      end
    end
  end

  # A tool module whose tail alias collides with a stdlib safe-exception name
  # turns the existing `raise StdlibName, ...` allow into a confused-deputy:
  # after `Legion.Sandbox.execute/4` prepends `alias MyApp.RuntimeError`, the
  # source `raise RuntimeError, "x"` compiles to `raise MyApp.RuntimeError, "x"`
  # — calling the tool's `exception/1`, force-loading that module, and running
  # whatever `@on_load` or `exception/1` body the tool author placed there.
  # Refuse the tool list at check-time. (Same rationale as the documented tail
  # collisions for `System`/`Code`/`File`, but for the raise allowlist
  # specifically — no static rewrite of `raise StdlibName` can distinguish
  # tool from stdlib, since they share the alias.)
  defp check_tool_collisions(allowed_modules) do
    safe_tails = MapSet.new(Enum.map(@safe_exceptions, &alias_tail/1))

    Enum.find_value(allowed_modules, :ok, fn mod ->
      tail = alias_tail(mod)

      if MapSet.member?(safe_tails, tail) and mod != tail do
        {:error,
         "tool module #{inspect(mod)} shadows stdlib safe-exception #{inspect(tail)}; " <>
           "rename the tool to avoid the collision"}
      end
    end)
  end

  defp alias_tail(module) do
    module |> Module.split() |> List.last() |> List.wrap() |> Module.concat()
  end

  defp check_node(node, {:error, _} = error, _tools), do: {node, error}

  # `Foo.bar(args)` - elixir-style module call. Tail-alias matching is allowed
  # so callers can write a tool's short name (`Helper` for `MyApp.Helper`).
  defp check_node({{:., _, [{:__aliases__, _, parts}, func]}, _, _} = node, :ok, tools) do
    check_module_call(node, Module.concat(parts), func, tools, :alias_form)
  end

  # `:erlang_mod.bar(args)` or `:"Elixir.Foo".bar(args)` - atom-literal module
  # call. Tail-alias matching is **not** allowed here: a tool tail like `System`
  # must not match the real `:"Elixir.System"`.
  defp check_node({{:., _, [module, func]}, _, _} = node, :ok, tools) when is_atom(module) do
    check_module_call(node, module, func, tools, :atom_form)
  end

  # `var.fun(args)` / `var.fun` / `expr.fun(args)` - dynamic dispatch.
  # The `no_parens: true` form (intended for `m.key` map access) is also
  # rejected: `m.fun` on an atom-valued `m` resolves to `m.fun()` at runtime,
  # which gives 0-arity dispatch onto any module on the system, and the same
  # shape inside a capture (`&m.fun/n`) builds a function reference for any
  # arity. Use `m[:key]` (Access protocol) for map field access.
  defp check_node({{:., _, [_base, _func]}, _meta, args} = node, :ok, _tools)
       when is_list(args) do
    {node, {:error, "dynamic module dispatch is not allowed"}}
  end

  # `f.(args)` - anonymous function invocation. Allowed: the function value
  # was either created in-sandbox (only safe code can build it) or passed in
  # as a binding by the caller.
  defp check_node({{:., _, [_]}, _, _args} = node, :ok, _tools), do: {node, :ok}

  # Skip the bare `:.` dot node that appears as the head of a dot-tuple. The
  # prewalk visits it on its own; the surrounding dot-call clauses already
  # validated the call.
  defp check_node({:., _, _} = node, :ok, _tools), do: {node, :ok}

  # Special context macros parsed as zero-arity identifiers: reject explicitly
  # so they don't slip through as ordinary variables.
  defp check_node({form, _, context} = node, :ok, _tools)
       when is_atom(context) and
              form in [:__ENV__, :__MODULE__, :__CALLER__, :__DIR__, :__STACKTRACE__] do
    {node, {:error, "#{form} is not allowed"}}
  end

  # `&name/arity` - capture of a local-or-imported function. The inner
  # `{name, _, ctx}` would otherwise match the variable clause below
  # (`is_atom(nil)` is true), letting captures of denied imports - `&apply/3`,
  # `&send/2`, `&spawn/1`, `&binding/0`, `&list_to_atom/1`, `&dbg/1`, ... -
  # slip past the bare-form check and become invokable through `f.(...)`.
  # Mirror the bare-form policy: a function is captureable iff it would be
  # callable as a bare form. Qualified captures (`&Foo.bar/2`,
  # `&:erlang.halt/0`) wrap a dot-tuple inside the `/` and are caught by the
  # module-call clauses above.
  #
  # `&raise/n` and `&reraise/n` are special-cased: even though `raise` is in
  # `@allowed_bare_forms`, the capture form invokes `raise` with a runtime
  # value as the first argument, sidestepping the `@safe_exceptions` gate.
  # `(&raise/1).(:erlang)` would otherwise pass and force-load `:erlang`.
  defp check_node(
         {:&, _, [{:/, _, [{name, _, context}, arity]}]} = node,
         :ok,
         _tools
       )
       when is_atom(name) and is_atom(context) and is_integer(arity) do
    cond do
      name in [:raise, :reraise] ->
        {node,
         {:error,
          "&#{name}/#{arity} is not allowed " <>
            "(would bypass the safe-exception module check at runtime)"}}

      MapSet.member?(@allowed_bare_forms, name) ->
        {node, :ok}

      true ->
        {node, {:error, "&#{name}/#{arity} is not allowed"}}
    end
  end

  # Variable references: `{name, meta, context}` where `context` is an atom
  # (typically `nil` for user code, or the module that introduced the var).
  # Variables themselves are not calls and are always safe.
  defp check_node({name, _, context} = node, :ok, _tools)
       when is_atom(name) and is_atom(context) do
    {node, :ok}
  end

  # `raise Mod` / `raise Mod, args` / `reraise Mod, ...` - the runtime calls
  # `Mod.exception/1`, which loads the named module. Restrict the module to a
  # small allowlist of stdlib exceptions; otherwise a sandboxed caller can
  # force-load any module by name (and trigger its `@on_load`).
  defp check_node({form, _, [{:__aliases__, _, parts} | _]} = node, :ok, _tools)
       when form in [:raise, :reraise] do
    module = Module.concat(parts)

    if MapSet.member?(@safe_exceptions, module) do
      {node, :ok}
    else
      {node, {:error, "#{form} of #{inspect(module)} is not allowed"}}
    end
  end

  defp check_node({form, _, [module | _]} = node, :ok, _tools)
       when form in [:raise, :reraise] and is_atom(module) and not is_nil(module) and
              module != true and module != false do
    if MapSet.member?(@safe_exceptions, module) do
      {node, :ok}
    else
      {node, {:error, "#{form} of #{inspect(module)} is not allowed"}}
    end
  end

  # `raise "string"` / `raise "msg #{interp}"` - one-arg string form. Always
  # produces a `RuntimeError`; safe. The interpolated children are walked
  # separately by the prewalk so they go through their own validation.
  defp check_node({form, _, [arg | _]} = node, :ok, _tools)
       when form in [:raise, :reraise] and is_binary(arg) do
    {node, :ok}
  end

  # `raise "string" <> "rest"` and similar string-building expressions still
  # produce a `RuntimeError` at runtime (not a module load), so allow them
  # if the LHS resolves to a binary at AST time. Most user code reaches
  # this clause for `raise "msg #{x}"` where the AST is a `<<>>` segment
  # (handled by the next clause).
  defp check_node({form, _, [{:<<>>, _, _segments} | _]} = node, :ok, _tools)
       when form in [:raise, :reraise] do
    {node, :ok}
  end

  # `raise <expr>` / `reraise <expr>, ...` where `<expr>` is anything other
  # than a literal alias, atom-literal exception module, binary, or string
  # interpolation. At runtime, `Kernel.raise/2` calls `mod.exception/1` on
  # whatever module atom `<expr>` evaluates to, force-loading the module
  # and triggering its `@on_load`. Indirection forms verified to bypass the
  # literal-only clauses above:
  #
  #     v = :asn1rt_nif; raise v
  #     raise hd([SomeMod])
  #     raise (fn -> SomeMod end).()
  #     raise Map.get(%{a: SomeMod}, :a)
  #     raise SomeTool.return_a_module()
  #
  # The user can still write the existing literal forms (`raise ArgumentError,
  # "msg"`, `raise "string"`, `raise "msg #{x}"`); everything else is denied.
  defp check_node({form, _, [_arg | _]} = node, :ok, _tools)
       when form in [:raise, :reraise] do
    {node,
     {:error,
      "#{form} requires a literal exception module from the safe-exceptions " <>
        "allowlist or a literal string; dynamic / indirected first arguments " <>
        "are rejected (would force-load arbitrary modules at runtime)"}}
  end

  # Bare-form call: `{name, meta, args}` with args a list. `name` must be in
  # `@allowed_bare_forms` - this is what catches `def`, `defstruct`, `apply`,
  # `__MODULE__`, `spawn`, `send`, `receive`, `__ENV__`, `__CALLER__`,
  # `__DIR__`, `__STACKTRACE__`, `binding`, `var!`, `alias!`, `dbg`, `super`.
  defp check_node({name, _, args} = node, :ok, _tools)
       when is_atom(name) and is_list(args) do
    if MapSet.member?(@allowed_bare_forms, name) do
      {node, :ok}
    else
      {node, {:error, "#{name} is not allowed"}}
    end
  end

  # Reject the literal atom `:__struct__` and any binary literal containing
  # the substring `"__struct__"`. A map with an `__struct__` key is dispatched
  # as a struct by every protocol in the BEAM, so sandbox code that can
  # construct one (`%{__struct__: M, ...}`, `Map.put(m, :__struct__, M)`, ...)
  # reaches any protocol impl in the runtime - most directly, fake
  # `%File.Stream{}` passed to `for ..., into: ...` to write arbitrary files.
  #
  # The string check is a *substring* check, not exact equality: `~w(_a
  # __struct__)a` parses to a sigil call whose literal argument is the binary
  # `"_a __struct__"`. At macro-expansion time (which `Code.eval_string`
  # performs after the AST check), `sigil_w` with the `a` modifier maps the
  # tokens through `String.to_atom/1`, materialising `:__struct__` despite
  # both `String.to_atom` and the literal atom being denied. Same for
  # `~W(...)a`, leading/trailing whitespace, mixed case wrappers, etc.
  # Blocking any binary that contains the substring closes every
  # source-string path to the atom.
  defp check_node(:__struct__ = node, :ok, _tools) do
    {node, {:error, "literal :__struct__ atom is not allowed"}}
  end

  defp check_node(node, :ok, _tools) when is_binary(node) do
    if String.contains?(node, "__struct__") do
      {node,
       {:error,
        ~S|literal binary containing "__struct__" is not allowed | <>
          "(would materialise the :__struct__ atom via sigil_w/sigil_W " <>
          "with the `a` modifier at macro-expansion time)"}}
    else
      {node, :ok}
    end
  end

  defp check_node(node, acc, _tools), do: {node, acc}

  defp check_module_call(node, module, func, tools, form) do
    {tool_modules, tool_aliases} = tools

    in_tools? =
      MapSet.member?(tool_modules, module) or
        (form == :alias_form and MapSet.member?(tool_aliases, module))

    with {:cont, {node, :ok}} <- module_call_allowed(node, module, func, in_tools?),
         :ok <- check_calendar_args(node, module, tool_modules) do
      {node, :ok}
    else
      {:halt, result} -> result
      {:error, _} = err -> {node, err}
    end
  end

  defp module_call_allowed(node, _module, _func, true = _in_tools?), do: {:cont, {node, :ok}}

  defp module_call_allowed(node, module, func, false) do
    if Map.has_key?(@builtin_module_functions, module) do
      if MapSet.member?(@builtin_module_functions[module], func) do
        {:cont, {node, :ok}}
      else
        {:halt, {node, {:error, "#{inspect(module)}.#{func} is not allowed"}}}
      end
    else
      {:halt, {node, {:error, "Module #{inspect(module)} is not allowed"}}}
    end
  end

  # Date/DateTime/NaiveDateTime/Time/Calendar functions accept a `Calendar`
  # or time-zone-database module argument that is dispatched at runtime
  # (`module.day_of_week/3`, `module.time_zone_period_from_utc_iso_days/2`,
  # ...). The runtime dispatch is the load primitive: `Date.new(2026, 1, 1,
  # EvilCal)` triggers `EvilCal.month/3` → BEAM module loader → `@on_load`.
  #
  # Conservative gate: refuse any literal alias / atom-literal module
  # reference appearing as an argument to a function on a calendar module
  # unless it points at a known-safe calendar module (`Calendar.ISO`,
  # `Calendar.UTCOnlyTimeZoneDatabase`) or a tool module the caller already
  # trusts. Variables / fn-call results are also refused: there is no path
  # for sandboxed code to obtain an evil module atom in a variable without
  # a literal alias or `*.to_atom`-style indirection (both blocked), so this
  # only constrains contrived expressions that would otherwise need a runtime
  # value the user can't actually produce.
  defp check_calendar_args({_dot, _meta, args}, module, tool_modules)
       when is_list(args) do
    if MapSet.member?(@calendar_modules, module) do
      Enum.reduce_while(args, :ok, fn arg, :ok ->
        case calendar_arg_disposition(arg, tool_modules) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
    else
      :ok
    end
  end

  defp check_calendar_args(_node, _module, _tool_modules), do: :ok

  # Classify a single argument expression appearing to a calendar function:
  #
  # * literal alias / atom-literal pointing at a safe calendar / tool module ->
  #   accept;
  # * literal alias / atom-literal pointing anywhere else -> reject (this is
  #   the `Date.new(_, _, _, EvilMod)` case);
  # * any non-module-shaped literal (number, string, list, tuple, map, ...)
  #   or any non-literal expression (variable, fn call, capture, ...) ->
  #   accept (unrelated to module dispatch).
  defp calendar_arg_disposition({:__aliases__, _, parts}, tool_modules) do
    module = Module.concat(parts)
    classify_calendar_module(module, tool_modules)
  end

  defp calendar_arg_disposition(atom, tool_modules)
       when is_atom(atom) and not is_nil(atom) and atom != true and atom != false do
    if elixir_module_atom?(atom) do
      classify_calendar_module(atom, tool_modules)
    else
      :ok
    end
  end

  defp calendar_arg_disposition(_other, _tool_modules), do: :ok

  defp classify_calendar_module(module, tool_modules) do
    cond do
      MapSet.member?(@safe_calendar_modules, module) -> :ok
      MapSet.member?(tool_modules, module) -> :ok
      MapSet.member?(@calendar_modules, module) -> :ok
      true ->
        {:error,
         "module #{inspect(module)} passed to a calendar function would be " <>
           "dispatched at runtime; only #{inspect(MapSet.to_list(@safe_calendar_modules))} " <>
           "or tool modules are allowed in calendar argument positions"}
    end
  end

  defp elixir_module_atom?(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> _ -> true
      _ -> false
    end
  end
end
