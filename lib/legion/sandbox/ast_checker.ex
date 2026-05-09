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
    If `expr` evaluates to a module atom at runtime, the call dispatches to
    arbitrary code on that module. This includes `m.key` map field access:
    use `Map.fetch!(m, :key)` or `Map.get(m, :key)` instead.
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

  # Bare forms: every non-prefixed call/identifier in user code must resolve
  # to one of these. Anything outside this set (def*, alias/import/require/use,
  # quote, apply, spawn*, send, receive, __ENV__/__MODULE__/__CALLER__/etc,
  # binding, var!, alias!, dbg, super) is rejected.

  @allowed_special_forms ~w(
    __aliases__ __block__ -> <- |
    {} %{} <<>>
    fn case cond if unless for with try when
    = ^ :: ..  ..// & \\
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

  # Built-in modules with per-function allowlists.

  # Kernel: notably absent are spawn*, send, receive, apply, def*, *_to_atom*,
  # function_exported?, macro_exported?, var!, alias!, binding, dbg, use,
  # spawn_request, and `node` (the node atom is needed to forge a valid
  # `%File.Stream{}` on distributed VMs). `raise`/`reraise` are also absent:
  # they're handled only via bare forms gated by the dedicated clauses below;
  # `Kernel.raise` (or `&Kernel.raise/1`) would bypass the `@safe_exceptions`
  # check.
  @kernel_allowed ~w(
    abs binary_part binary_slice bit_size byte_size ceil div elem exit floor
    get_and_update_in get_in hd inspect length make_ref map_size max min
    pop_in put_elem put_in rem round self tap then throw tl
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

  # Map: `keys` and `to_list` are absent — they leak `:__struct__` from any
  # struct value, which sandboxed code could then route through `Map.put` to
  # build a fake struct (e.g. forge `%File.Stream{}` to write files via `for
  # ..., into:`). `values/1` is kept: it doesn't expose the `:__struct__` key,
  # which is the literal needed to repopulate the struct slot.
  @map_allowed ~w(
    delete drop equal? fetch fetch! filter from_keys from_struct get
    get_and_update get_and_update! get_lazy has_key? intersect map merge
    new pop pop! pop_lazy put put_new put_new_lazy reject replace replace!
    replace_lazy size split split_with take update update! values
  )a

  @mapset_allowed ~w(
    delete difference disjoint? equal? filter intersection member? new put
    reject size split_with subset? symmetric_difference to_list union
  )a

  # List: `to_atom` / `to_existing_atom` are omitted — the latter lets
  # sandboxed code reconstruct `:__struct__` from bytewise-built charlists,
  # defeating the literal-atom rejection.
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

  # Atom: only conversions away from atoms.
  @atom_allowed ~w(to_charlist to_string)a

  # Regex: compile/compile! are safe; the regex engine is bounded.
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

  # Calendar: read-only only — `put_time_zone_database` mutates global env.
  @calendar_allowed ~w(
    compatible_calendars? get_time_zone_database strftime truncate
  )a

  @math_allowed ~w(
    acos acosh asin asinh atan atan2 atanh ceil cos cosh erf erfc exp floor
    fmod log log10 log2 pi pow sin sinh sqrt tan tanh tau
  )a

  # JSON: pure data in/out, no atoms materialised by default.
  @json_allowed ~w(decode decode! encode! encode_to_iodata!)a

  # URI: pure data. `default_port/2` is omitted (the 2-arity form mutates a
  # global scheme->port table); both arities share the name.
  @uri_allowed ~w(
    append_query char_reserved? char_unescaped? char_unreserved?
    decode decode_query decode_www_form encode encode_query
    encode_www_form merge new new! parse query_decoder to_string
  )a

  # Only `:erlang.float_to_binary/2` (fixed-precision float formatting); other
  # erlang BIFs are blocked.
  @erlang_allowed ~w(float_to_binary)a

  # Modules whose functions take a Calendar / time-zone-DB module argument
  # that's dispatched at runtime — see `check_calendar_args/3`.
  @calendar_modules MapSet.new([Date, DateTime, NaiveDateTime, Time, Calendar])

  @safe_calendar_modules MapSet.new([Calendar.ISO, Calendar.UTCOnlyTimeZoneDatabase])

  # Stdlib struct modules safe in the `%Mod{...}` form. Any other module would
  # be force-loaded at runtime (running its `@on_load`). All listed modules
  # are pure data structs preloaded in a normal Elixir runtime.
  @safe_struct_modules MapSet.new([
                         Date,
                         DateTime,
                         NaiveDateTime,
                         Time,
                         Range,
                         Regex,
                         MapSet,
                         Version,
                         Version.Requirement,
                         URI
                       ])

  # Exception modules safe as the first arg to `raise`/`reraise`. Any other
  # module would be force-loaded at runtime via `Mod.exception/1`.
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
    JSON => MapSet.new(@json_allowed),
    URI => MapSet.new(@uri_allowed),
    :math => MapSet.new(@math_allowed),
    :erlang => MapSet.new(@erlang_allowed)
  }

  @max_code_size 64 * 1024

  # An atom that could refer to an Elixir / Erlang module: rules out `nil`,
  # `true`, `false`, which are atoms but not module references. Used wherever
  # an AST position can hold either a module-atom literal or one of those
  # three special atoms.
  defguardp is_module_atom(x) when is_atom(x) and x not in [nil, true, false]

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

  # A tool whose tail alias matches a stdlib safe-exception name would
  # confused-deputy the `raise StdlibName, ...` rule: after the host prepends
  # `alias MyApp.RuntimeError`, `raise RuntimeError` compiles to `raise
  # MyApp.RuntimeError`, force-loading the tool. Refuse such tool lists.
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

  # AST walker. Clause order is load-bearing: the capture clause must precede
  # the variable clause, and the `:__struct__` / binary-literal leaf clauses
  # must come after the bare-form clause.

  defp check_node(node, {:error, _} = error, _tools), do: {node, error}

  # `Foo.bar(args)` - alias form. Tail aliases match (callers can write a
  # tool's short name).
  defp check_node({{:., _, [{:__aliases__, _, parts}, func]}, _, _} = node, :ok, tools) do
    check_module_call(node, Module.concat(parts), func, tools, :alias_form)
  end

  # `:atom_mod.bar(args)` - atom-literal form. Tail aliases do *not* match,
  # so a tool tail like `System` cannot unlock `:"Elixir.System"`.
  defp check_node({{:., _, [module, func]}, _, _} = node, :ok, tools) when is_atom(module) do
    check_module_call(node, module, func, tools, :atom_form)
  end

  # `var.fun(args)` / `m.key` / `&m.fun/n` - dynamic dispatch. If `var` is a
  # module atom at runtime, this calls arbitrary code on that module.
  defp check_node({{:., _, [_base, _func]}, _meta, args} = node, :ok, _tools)
       when is_list(args) do
    {node,
     {:error,
      "dynamic dispatch (`expr.fun` / `expr.fun(...)`) is not allowed - if " <>
        "`expr` is a module atom, this calls arbitrary code on that module. " <>
        "Use `Map.fetch!(map, :field)` or `Map.get(map, :field)` for map / struct fields."}}
  end

  # `f.(args)` anonymous-function invocation, and the bare `:.` dot head that
  # the prewalk visits on its own. The surrounding dot-call clauses already
  # validated anything reachable through these.
  defp check_node({{:., _, [_]}, _, _args} = node, :ok, _tools), do: {node, :ok}
  defp check_node({:., _, _} = node, :ok, _tools), do: {node, :ok}

  # Special context macros parsed as zero-arity identifiers - reject so they
  # don't slip through the variable clause below.
  defp check_node({form, _, context} = node, :ok, _tools)
       when is_atom(context) and
              form in [:__ENV__, :__MODULE__, :__CALLER__, :__DIR__, :__STACKTRACE__] do
    {node, {:error, "#{form} is not allowed"}}
  end

  # `&name/arity` - local/imported capture. Must precede the variable clause:
  # the inner `{name, _, ctx}` would otherwise match it (since `is_atom(nil)`
  # is true), letting captures of denied imports (`&apply/3`, `&send/2`,
  # `&binding/0`, `&dbg/1`, ...) become invokable via `f.(...)`. Qualified
  # captures (`&Foo.bar/2`) are handled by the module-call clauses above.
  #
  # `&raise/n` / `&reraise/n` are explicitly denied even though they're in
  # `@allowed_bare_forms`: the capture form passes its first argument at
  # runtime, sidestepping the `@safe_exceptions` gate.
  defp check_node({:&, _, [{:/, _, [{name, _, context}, arity]}]} = node, :ok, _tools)
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

  # Variable reference - always safe (it's not a call).
  defp check_node({name, _, context} = node, :ok, _tools)
       when is_atom(name) and is_atom(context),
       do: {node, :ok}

  # `%Mod{...}` struct literal. The runtime force-loads `Mod` (and runs its
  # `@on_load`), so `Mod` must be a known-safe struct, safe exception, or
  # tool. Tail-alias matching is alias-form-only.
  defp check_node({:%, _, [{:__aliases__, _, parts}, _map]} = node, :ok, tools),
    do: check_struct_literal(node, Module.concat(parts), tools, :alias_form)

  defp check_node({:%, _, [module, _map]} = node, :ok, tools) when is_module_atom(module),
    do: check_struct_literal(node, module, tools, :atom_form)

  # `raise <arg>, ...` / `reraise <arg>, ...`. The first argument is gated;
  # trailing args are recursed by the prewalk. Anything other than a literal
  # alias / atom-literal exception module, binary, or `<<>>` interpolation is
  # rejected — at runtime `Kernel.raise/2` would call `mod.exception/1` on
  # whatever module atom `<arg>` evaluates to and force-load it. Verified
  # bypass shapes (all rejected here): `v = :m; raise v`, `raise hd([M])`,
  # `raise (fn -> M end).()`, `raise Map.get(%{a: M}, :a)`, `raise tool.fun()`.
  defp check_node({form, _, [arg | _]} = node, :ok, _tools)
       when form in [:raise, :reraise] do
    {node, check_raise_arg(form, arg)}
  end

  # Bare-form call - catches `def`, `defstruct`, `apply`, `spawn`, `send`,
  # `receive`, `binding`, `var!`, `dbg`, ... (anything not in
  # `@allowed_bare_forms`).
  defp check_node({name, _, args} = node, :ok, _tools)
       when is_atom(name) and is_list(args) do
    if MapSet.member?(@allowed_bare_forms, name) do
      {node, :ok}
    else
      {node, {:error, bare_form_denied_error(name)}}
    end
  end

  # Reject the literal atom `:__struct__` and any binary that *contains* the
  # substring `"__struct__"`. A map with an `__struct__` key is dispatched as
  # a struct by every BEAM protocol — fake `%File.Stream{}` via `for ...,
  # into: fake` writes arbitrary files. The substring check (not equality)
  # blocks `~w(_a __struct__)a` and friends, where `sigil_w` with `a` maps
  # tokens through `String.to_atom/1` at macro-expansion time.
  defp check_node(:__struct__ = node, :ok, _tools),
    do: {node, {:error, "literal :__struct__ atom is not allowed"}}

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

  defp check_module_call(node, module, func, {tool_modules, tool_aliases}, form) do
    cond do
      MapSet.member?(tool_modules, module) ->
        {node, check_calendar_args(node, module, tool_modules)}

      form == :alias_form and MapSet.member?(tool_aliases, module) ->
        {node, check_calendar_args(node, module, tool_modules)}

      not Map.has_key?(@builtin_module_functions, module) ->
        {node, {:error, module_denied_error(module)}}

      not MapSet.member?(@builtin_module_functions[module], func) ->
        {node, {:error, function_denied_error(module, func)}}

      true ->
        {node, check_calendar_args(node, module, tool_modules)}
    end
  end

  defp check_struct_literal(node, module, {tool_modules, tool_aliases}, form) do
    in_tools? =
      MapSet.member?(tool_modules, module) or
        (form == :alias_form and MapSet.member?(tool_aliases, module))

    if in_tools? or MapSet.member?(@safe_struct_modules, module) or
         MapSet.member?(@safe_exceptions, module) do
      {node, :ok}
    else
      {node, {:error, struct_literal_error(module)}}
    end
  end

  defp check_raise_arg(form, {:__aliases__, _, parts}),
    do: check_raise_module(form, Module.concat(parts))

  defp check_raise_arg(form, module) when is_module_atom(module),
    do: check_raise_module(form, module)

  defp check_raise_arg(_form, arg) when is_binary(arg), do: :ok
  defp check_raise_arg(_form, {:<<>>, _, _segments}), do: :ok

  defp check_raise_arg(form, _arg) do
    {:error,
     "#{form} requires a literal exception module from the safe-exceptions " <>
       "allowlist or a literal string; dynamic / indirected first arguments " <>
       "are rejected (would force-load arbitrary modules at runtime)"}
  end

  defp check_raise_module(form, module) do
    if MapSet.member?(@safe_exceptions, module),
      do: :ok,
      else: {:error, "#{form} of #{inspect(module)} is not allowed"}
  end

  @module_hint %{
    IO => "return values from your code instead of printing them; the host displays them automatically",
    Code => "dynamic code evaluation is not permitted",
    Process => "process / message manipulation is not permitted",
    File => "file I/O is not permitted (ask the caller for a tool that exposes the data you need)",
    System => "host introspection / shell-out is not permitted",
    :erlang => "only :erlang.float_to_binary/2 is exposed; other erlang BIFs are blocked"
  }

  defp module_denied_error(module) do
    hint =
      Map.get(
        @module_hint,
        module,
        "the host only exposes a fixed set of safe stdlib modules plus the tools you were given"
      )

    "Module #{inspect(module)} is not allowed in the sandbox - #{hint}"
  end

  defp function_denied_error(Map, func) when func in [:keys, :to_list] do
    "Map.#{func} is not allowed - it would leak the :__struct__ atom from " <>
      "any struct value. Use `Map.values/1` or `Enum.map(map, fn {k, _} -> k end)`."
  end

  defp function_denied_error(module, func)
       when module in [Atom, String, List] and func in [:to_atom, :to_existing_atom] do
    "#{inspect(module)}.#{func} is not allowed - dynamic atom construction can " <>
      "grow the atom table or reconstruct denied atoms."
  end

  defp function_denied_error(Kernel, :apply) do
    "Kernel.apply is not allowed - call the function directly: `Module.fun(arg1, arg2)`."
  end

  defp function_denied_error(Kernel, :raise) do
    "Kernel.raise is not allowed - use the bare form `raise ExceptionModule, \"msg\"` " <>
      "with a stdlib exception, or `raise \"msg\"`."
  end

  defp function_denied_error(Kernel, func) when func in [:send, :spawn] do
    hint =
      case func do
        :send -> "inter-process messaging is not permitted in the sandbox."
        :spawn -> "process creation is not permitted in the sandbox."
      end

    "Kernel.#{func} is not allowed - #{hint}"
  end

  defp function_denied_error(module, func) do
    "#{inspect(module)}.#{func} is not allowed in the sandbox"
  end

  defp struct_literal_error(module) do
    "%#{inspect(module)}{} is not allowed - the runtime would force-load " <>
      "#{inspect(module)} (and run its `@on_load`). Allowed: " <>
      "#{inspect(MapSet.to_list(@safe_struct_modules))}, safe stdlib " <>
      "exceptions, and tool modules. For pattern matching, use a plain map " <>
      "pattern (`%{key: val}`)."
  end

  @def_forms ~w(def defp defmodule defmacro defmacrop defstruct defexception
                defprotocol defimpl defdelegate defguard defguardp defoverridable)a
  @directive_forms ~w(alias import require use)a
  @spawn_forms ~w(spawn spawn_link spawn_monitor)a
  @msg_forms ~w(send receive)a
  @macro_forms ~w(quote unquote unquote_splicing)a

  defp bare_form_hint(name) when name in @def_forms,
    do: "module / function definitions are not permitted. Use anonymous functions (`fn x -> ... end`) and `Enum.reduce/3` for stateful or recursive logic."

  defp bare_form_hint(name) when name in @directive_forms,
    do: "module directives are managed by the sandbox host. Tools are already aliased; reference them directly."

  defp bare_form_hint(:apply),
    do: "dynamic dispatch on a runtime module/function atom is not permitted. Call the function directly: `Module.fun(arg1, arg2)`."

  defp bare_form_hint(name) when name in @spawn_forms,
    do: "process creation is not permitted in the sandbox."

  defp bare_form_hint(name) when name in @msg_forms,
    do: "inter-process messaging is not permitted in the sandbox."

  defp bare_form_hint(:binding),
    do: "the sandbox host displays available bindings to you separately; reference variables by name."

  defp bare_form_hint(:dbg),
    do: "debug printing is not available; return values from your code instead."

  defp bare_form_hint(name) when name in @macro_forms,
    do: "macro / AST manipulation is not permitted in the sandbox."

  defp bare_form_hint(name),
    do: "if this is a function name, prefix it with its module (e.g. `Kernel.#{name}/1`); otherwise it is not permitted."

  defp bare_form_denied_error(name),
    do: "#{name} is not allowed in the sandbox - #{bare_form_hint(name)}"

  # Calendar functions dispatch a Calendar / time-zone-DB module argument at
  # runtime (`module.day_of_week/3`, ...). That dispatch loads the module and
  # runs its `@on_load`, so reject any literal module reference in those
  # positions unless it's a known-safe calendar or a tool.
  defp check_calendar_args({_dot, _meta, args}, module, tool_modules) when is_list(args) do
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

  defp calendar_arg_disposition({:__aliases__, _, parts}, tool_modules),
    do: classify_calendar_module(Module.concat(parts), tool_modules)

  defp calendar_arg_disposition(atom, tool_modules) when is_module_atom(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> _ -> classify_calendar_module(atom, tool_modules)
      _ -> :ok
    end
  end

  defp calendar_arg_disposition(_other, _tool_modules), do: :ok

  defp classify_calendar_module(module, tool_modules) do
    if MapSet.member?(@safe_calendar_modules, module) or
         MapSet.member?(@calendar_modules, module) or
         MapSet.member?(tool_modules, module) do
      :ok
    else
      {:error,
       "module #{inspect(module)} passed to a calendar function would be " <>
         "dispatched at runtime; only #{inspect(MapSet.to_list(@safe_calendar_modules))} " <>
         "or tool modules are allowed in calendar argument positions"}
    end
  end
end
