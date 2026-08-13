defmodule Legion.Tool do
  @moduledoc """
  `use Legion.Tool` to mark a module as a tool available to agents.

  By default, `description/0` returns the module's source code so the LLM
  knows what functions are available.

  ## Overridable

    - `description/0` — override to return a hand-written summary **instead of**
      the source code. Defaults to the module's source code.
    - `extra_allowed_modules/0` — override to return additional modules that the
      sandbox should alias and permit when this tool is available. Defaults to `[]`.
      Useful for tools like `Legion.Tools.AgentTool` that dispatch to other modules
      the agent needs to reference by name.

  ## Example

      defmodule MyApp.WeatherTool do
        use Legion.Tool

        def description do
          \"""
          WeatherTool — fetches current weather data.

          ## Functions
          - `current(city)` — returns weather JSON for the given city name.
          \"""
        end

        @doc "Returns current weather for a city."
        def current(city) do
          Req.get!("https://wttr.in/\#{city}?format=j1").body
        end
      end
  """

  @callback description() :: String.t()
  @callback description(sandbox :: module()) :: String.t()
  @callback extra_allowed_modules() :: [module()]

  @optional_callbacks description: 1

  defmacro __using__(_opts) do
    source = extract_module_source(File.read!(__CALLER__.file), __CALLER__.module)

    quote do
      @behaviour Legion.Tool

      def description, do: unquote(source)
      def extra_allowed_modules, do: []

      defoverridable description: 0, extra_allowed_modules: 0
    end
  end

  @doc false
  def extract_module_source(code, module) do
    module_header = "defmodule #{inspect(module)} do"
    lines = String.split(code, "\n")

    start_index =
      Enum.find_index(lines, &String.contains?(&1, module_header)) ||
        raise "Could not find #{module_header} in source file"

    end_line = find_matching_end_line(code, start_index + 1)

    lines
    |> Enum.slice(start_index, end_line - start_index)
    |> Enum.join("\n")
  end

  defp find_matching_end_line(code, start_line) do
    tokens = tokenize!(code)

    tokens
    |> Enum.reverse()
    |> Enum.reduce_while({0, nil}, fn token, {depth, _last_end_line} ->
      case token_line(token, start_line) do
        {:open, _line} -> {:cont, {depth + 1, nil}}
        {:close, line} when depth == 1 -> {:halt, {0, line}}
        {:close, line} -> {:cont, {depth - 1, line}}
        :skip -> {:cont, {depth, nil}}
      end
    end)
    |> case do
      {0, line} when is_integer(line) -> line
      _ -> raise "Could not find matching `end` for module starting on line #{start_line}"
    end
  end

  defp token_line({:do, {line, _, _}}, start_line) when line >= start_line, do: {:open, line}
  defp token_line({:fn, {line, _, _}}, start_line) when line >= start_line, do: {:open, line}
  defp token_line({:end, {line, _, _}}, start_line) when line >= start_line, do: {:close, line}
  defp token_line(_token, _start_line), do: :skip

  defp tokenize!(code) do
    case :elixir_tokenizer.tokenize(String.to_charlist(code), 1, []) do
      result when elem(result, 0) == :ok ->
        result
        |> Tuple.to_list()
        |> Enum.find([], &token_list?/1)

      {:error, reason, _, _, _} ->
        raise "Failed to tokenize source: #{inspect(reason)}"
    end
  end

  defp token_list?([head | _]) when is_tuple(head) and tuple_size(head) >= 2,
    do: is_atom(elem(head, 0))

  defp token_list?(_), do: false
end
