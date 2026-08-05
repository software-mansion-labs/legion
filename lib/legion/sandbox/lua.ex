defmodule Legion.Sandbox.Lua do
  @moduledoc """
  Sandboxed Lua evaluation via [luerl](https://github.com/rvirding/luerl)
  (through the [lua](https://hexdocs.pm/lua) wrapper) - a Lua VM written in
  pure Erlang.

  Unlike `Legion.Sandbox.Elixir`, which must deny-list its way around the
  entire Elixir surface, Lua code simply has no way to reach the host BEAM:
  the only bridges out of the VM are the tool functions registered by this
  module. That makes it the safer sandbox for less trusted code.

  - **Tools** - each tool module becomes a global Lua table named after the
    module's last segment; every public function is callable as
    `ShortName.fun(...)`. Arguments are decoded to Elixir values (Lua tables
    become maps, or lists when array-shaped) and results are encoded back
    (tuples become arrays, structs become tables of fields, atoms become
    strings).
  - **Bindings** - the opaque `Lua` state. Lua globals persist across
    executions that share bindings; `local` variables do not.
  - **Blocked** - `io`, `file`, `os.execute/exit/getenv/...`, `require`,
    `load`, `print`, and `debug` are sandboxed and raise when called.
  - **Timeout and resource limits** - evaluation runs through
    `Legion.Sandbox.Runner`, same as `Legion.Sandbox.Elixir`.

  ## Examples

      iex> {:ok, {4, _}} = Legion.Sandbox.Lua.execute("return 2 + 2", 5_000)

      iex> {:ok, {nil, bindings}} = Legion.Sandbox.Lua.execute("x = 40", 5_000)
      iex> {:ok, {42, _}} = Legion.Sandbox.Lua.execute("return x + 2", 5_000, [], bindings)

      iex> {:error, message} = Legion.Sandbox.Lua.execute("os.getenv('HOME')", 5_000)
      iex> message =~ "sandboxed"
      true
  """

  @behaviour Legion.Sandbox

  alias Legion.Sandbox.Runner

  require EEx

  EEx.function_from_file(:defp, :constraints, Path.join(__DIR__, "lua/constraints.eex"))

  @max_code_size 64 * 1024

  # Defined by `use Legion.Tool`, not part of a tool's callable surface.
  @tool_meta_functions [description: 0, extra_allowed_modules: 0]

  @baseline_globals_key :legion_baseline_globals

  # Field stamped on every bridged tool table so the table itself can stand in
  # for its Elixir module when passed back through a bridge.
  @module_key "__module"

  @impl Legion.Sandbox
  def check(code, _tools) when not is_binary(code),
    do: {:error, "code must be a binary, got: #{inspect(code)}"}

  def check(code, _tools) when byte_size(code) > @max_code_size,
    do: {:error, "code exceeds maximum size of #{@max_code_size} bytes"}

  def check(code, _tools) do
    case Lua.parse_chunk(code) do
      {:ok, _chunk} ->
        :ok

      {:error, errors} ->
        {:error,
         "Lua parse error:\n" <>
           Enum.join(errors, "\n") <>
           "\nNote: a bare expression is not a valid Lua statement - " <>
           "to produce a value, write `return <expression>`."}
    end
  end

  @impl Legion.Sandbox
  def binding_names(%Lua{} = lua) do
    baseline = Lua.get_private!(lua, @baseline_globals_key)
    global_names(lua) -- baseline
  end

  def binding_names(_fresh), do: []

  @impl Legion.Sandbox
  def prompt_info do
    %{
      language: "Lua",
      constraints: constraints(),
      tool_usage:
        "Each tool below is implemented in Elixir and exposed as a global Lua table - call it from Lua as `ShortName.fun(...)`. The source shown is Elixir; call the same function names with positional arguments."
    }
  end

  @doc """
  Evaluates Lua `code` in a sandboxed process.

  `timeout_ms` controls the maximum execution time (`:infinity` to disable).
  `tools` are Elixir modules bridged in as global Lua tables. `limits` bound
  the evaluating process - see `Legion.Sandbox.Runner.run/3`.

  Returns `{:ok, {result, bindings}}` where `result` is the chunk's `return`
  value (`nil` when it returns nothing) and `bindings` is the Lua state to
  pass to subsequent calls, or `{:error, reason}`.
  """
  @impl Legion.Sandbox
  def execute(code, timeout_ms, tools \\ [], bindings \\ [], limits \\ [])
      when is_binary(code) and is_list(tools) do
    with :ok <- check(code, tools) do
      Runner.run(fn -> eval(code, tools, bindings) end, timeout_ms, limits)
    end
  end

  defp eval(code, tools, bindings) do
    lua = if bindings == [], do: init(tools), else: bindings
    module_refs = module_refs(tools)

    {results, lua} = Lua.eval!(lua, code)

    # luerl never garbage-collects on its own, so without this sweep dead
    # tables from every evaluation accumulate in the state - and in every
    # persisted snapshot of it - for the life of the conversation.
    lua = %{lua | state: :luerl.gc(lua.state)}

    value =
      case results do
        [] -> nil
        [single] -> lua_to_elixir(single, module_refs)
        many -> Enum.map(many, &lua_to_elixir(&1, module_refs))
      end

    {:ok, {value, lua}}
  rescue
    e in [Lua.RuntimeException, Lua.CompilerException] -> {:error, Exception.message(e)}
  end

  defp init(tools) do
    lua =
      Lua.new()
      |> Lua.sandbox([:print])
      |> Lua.sandbox([:debug])
      |> register_tools(tools)

    Lua.put_private(lua, @baseline_globals_key, global_names(lua))
  end

  defp module_refs(tools), do: Map.new(tools, &{Atom.to_string(&1), &1})

  defp register_tools(lua, tools) do
    module_refs = module_refs(tools)

    for tool <- tools, reduce: lua do
      lua ->
        short_name = tool |> Module.split() |> List.last()

        # The marker lets sandboxed code pass the table itself where an Elixir
        # module is expected (`AgentTool.call(PlannerAgent, task)`) - the
        # bridge resolves marked tables back to their module atom.
        lua = Lua.set!(lua, [short_name, @module_key], Atom.to_string(tool))

        for {name, arities} <- callable_functions(tool), reduce: lua do
          lua ->
            Lua.set!(
              lua,
              [short_name, Atom.to_string(name)],
              bridge(tool, short_name, name, arities, module_refs)
            )
        end
    end
  end

  defp callable_functions(tool) do
    Code.ensure_loaded!(tool)

    tool.__info__(:functions)
    |> Kernel.--(@tool_meta_functions)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp bridge(tool, short_name, name, arities, module_refs) do
    fn encoded_args, lua ->
      args = for arg <- Lua.decode_list!(lua, encoded_args), do: lua_to_elixir(arg, module_refs)

      if length(args) in arities do
        result =
          try do
            apply(tool, name, args)
          rescue
            e ->
              reraise Lua.RuntimeException,
                      "#{short_name}.#{name}: #{Exception.message(e)}",
                      __STACKTRACE__
          end

        {encoded, lua} = Lua.encode!(lua, elixir_to_lua(result))
        {[encoded], lua}
      else
        raise Lua.RuntimeException,
              "#{short_name}.#{name} takes #{Enum.join(arities, " or ")} argument(s), " <>
                "got #{length(args)}"
      end
    end
  end

  defp global_names(lua) do
    {[names], _lua} =
      Lua.eval!(lua, """
      local names = {}
      for name in pairs(_G) do names[#names + 1] = name end
      return names
      """)

    for {_index, name} <- names, do: name
  end

  # Decoded Lua values -> Elixir. Tables carrying the bridge's module marker
  # resolve to their module atom; array-shaped tables (keys exactly 1..n)
  # become lists; the rest become maps.
  defp lua_to_elixir(table, module_refs) when is_list(table) do
    cond do
      module = bridged_module(table, module_refs) ->
        module

      Enum.map(table, &elem(&1, 0)) == Enum.to_list(1..length(table)//1) ->
        for {_index, value} <- table, do: lua_to_elixir(value, module_refs)

      true ->
        Map.new(table, fn {key, value} ->
          {lua_to_elixir(key, module_refs), lua_to_elixir(value, module_refs)}
        end)
    end
  end

  defp lua_to_elixir(other, _module_refs), do: other

  defp bridged_module(table, module_refs) do
    case List.keyfind(table, @module_key, 0) do
      {@module_key, name} -> module_refs[name]
      nil -> nil
    end
  end

  # Elixir values -> something luerl can encode. Tuples and structs have no
  # Lua counterpart: tuples become arrays, structs lose their module.
  defp elixir_to_lua(%_{} = struct), do: struct |> Map.from_struct() |> elixir_to_lua()

  defp elixir_to_lua(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {elixir_to_lua(key), elixir_to_lua(value)} end)

  defp elixir_to_lua(list) when is_list(list), do: Enum.map(list, &elixir_to_lua/1)

  defp elixir_to_lua(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&elixir_to_lua/1)

  defp elixir_to_lua(other), do: other
end
