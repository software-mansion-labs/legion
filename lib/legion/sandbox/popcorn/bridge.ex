defmodule Legion.Sandbox.Popcorn.Bridge do
  @moduledoc false
  # The JSON boundary of the Popcorn sandbox. Mirrors the Lua bridge's
  # lossiness rules (tuples -> arrays, atoms -> strings, structs -> plain
  # string-keyed maps) and marks tool modules so they survive the round trip.

  @module_key "__legion_module"
  # Defined by `use Legion.Tool`, not part of a tool's callable surface.
  @tool_meta_functions [description: 0, extra_allowed_modules: 0]

  @doc "Tool description shipped to the browser so it can define stub modules."
  def manifest(tools) do
    for tool <- tools do
      functions =
        for {fun, arities} <- callable_functions(tool) do
          %{name: Atom.to_string(fun), arities: arities}
        end

      %{name: short_name(tool), module: Atom.to_string(tool), functions: functions}
    end
  end

  def short_name(module), do: module |> Module.split() |> List.last()

  def module_refs(tools), do: Map.new(tools, &{short_name(&1), &1})

  @doc "Public functions of a `Legion.Tool` module; `%{}` for anything else."
  def callable_functions(tool) do
    Code.ensure_loaded!(tool)

    if legion_tool?(tool) do
      tool.__info__(:functions)
      |> Kernel.--(@tool_meta_functions)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    else
      %{}
    end
  end

  defp legion_tool?(module) do
    behaviours =
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    Legion.Tool in behaviours
  end

  @doc "Elixir term -> JSON-encodable term (lossy, like the Lua bridge)."
  def encode(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {encode_key(key), encode(value)} end)

  def encode(%_{} = struct), do: struct |> Map.from_struct() |> encode()
  def encode(list) when is_list(list), do: Enum.map(list, &encode/1)
  def encode(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> encode()
  def encode(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  def encode(nil), do: nil
  def encode(atom) when is_atom(atom), do: Atom.to_string(atom)
  def encode(other), do: inspect(other)

  defp encode_key(key) do
    case encode(key) do
      bin when is_binary(bin) -> bin
      other -> inspect(other)
    end
  end

  @doc "JSON-decoded term -> Elixir, resolving module markers to allowed modules."
  def decode(%{@module_key => short} = map, module_refs) when map_size(map) == 1 do
    Map.get(module_refs, short, map)
  end

  def decode(map, module_refs) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, decode(value, module_refs)} end)

  def decode(list, module_refs) when is_list(list), do: Enum.map(list, &decode(&1, module_refs))
  def decode(other, _module_refs), do: other
end
