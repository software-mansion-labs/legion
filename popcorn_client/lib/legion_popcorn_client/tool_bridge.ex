defmodule LegionPopcornClient.ToolBridge do
  @moduledoc false
  # The worker-process side of tool calls: sends a `legion_tool_call` event
  # to the main window (which relays it to the server over the channel) and
  # blocks until the reply is cast back to this process
  # (`popcorn.cast(["tool_reply", id, result], {process: "legion_popcorn_worker"})`).

  alias Popcorn.Wasm
  require Popcorn.Wasm

  @manifest_key :legion_tool_manifest
  @counter_key :legion_tool_call_counter

  @doc "Remembers the manifest's short names in the calling (worker) process."
  def put_manifest(manifest) do
    shorts = for %{"name" => name} <- manifest, into: MapSet.new(), do: name
    Process.put(@manifest_key, shorts)
    :ok
  end

  @doc "Called by generated stub modules."
  def call(tool, fun, args) do
    id = next_id()
    Wasm.send_event("legion_tool_call", %{id: id, tool: tool, fun: fun, args: json_safe(args)})
    await_reply(id)
  end

  defp next_id do
    id = Process.get(@counter_key, 0) + 1
    Process.put(@counter_key, id)
    id
  end

  defp await_reply(id) do
    receive do
      raw when Wasm.is_wasm_message(raw) ->
        case Wasm.parse_message!(raw) do
          {:wasm_cast, ["tool_reply", ^id, %{"status" => "ok"} = reply]} ->
            Map.get(reply, "value")

          {:wasm_cast, ["tool_reply", ^id, %{"status" => "error"} = reply]} ->
            raise RuntimeError, Map.get(reply, "message", "tool call failed")

          _other ->
            await_reply(id)
        end
    end
  end

  @doc "Best-effort JSON-safe conversion, mirroring the server Bridge rules."
  def json_safe(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {json_safe_key(k), json_safe(v)} end)

  def json_safe(%_{} = struct), do: struct |> Map.from_struct() |> json_safe()
  def json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  def json_safe(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json_safe()
  def json_safe(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  def json_safe(nil), do: nil

  def json_safe(atom) when is_atom(atom) do
    name = Atom.to_string(atom)
    shorts = Process.get(@manifest_key, MapSet.new())

    case name do
      "Elixir." <> short ->
        if MapSet.member?(shorts, short), do: %{"__legion_module" => short}, else: name

      _plain ->
        name
    end
  end

  def json_safe(other), do: inspect(other)

  defp json_safe_key(key) do
    case json_safe(key) do
      bin when is_binary(bin) -> bin
      other -> inspect(other)
    end
  end
end
