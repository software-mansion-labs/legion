defmodule Legion.Agent do
  @moduledoc """
  `use Legion.Agent` to define your agent.

  ## Example

      defmodule MyAgent do
        @moduledoc "Researches topics and summarises findings."

        use Legion.Agent

        def tools, do: [MyApp.SearchTool, Legion.Tools.HumanTool]

        def tool_config(Legion.Tools.HumanTool), do: [handler: MyApp.ChatHandler, timeout: 30_000]

        def output_schema, do: %{"type" => "object", "properties" => %{"summary" => %{"type" => "string"}}}
      end

  ## Callbacks

  All callbacks are optional.

    - `tools/0` — list of tool modules available to the agent. Each tool's
      `tool_config/1` result is stored in the Vault under the tool's module key.
      Defaults to `[]`.

    - `tool_config/1` — per-tool configuration. Receives a tool module, returns a
      keyword list. The returned options are accessible to the tool at runtime via
      `Vault.get(__MODULE__)`. Defaults to `[]` for all tools.

    - `system_prompt/0` — override to return a fully custom system prompt. When
      not defined, the prompt is auto-generated from `@moduledoc`, tool source
      code, and the resolved `binding_scope`.

    - `output_schema/0` — JSON Schema map describing the agent's structured output.
      Used by the LLM for the `result` field. Defaults to `%{"type" => "string"}`.

    - `config/0` — agent-level configuration merged with application config and
      call-time opts. Defaults to `%{}`. Available keys:
      - `model` — LLM model identifier (default: `"openai:gpt-5.4"`)
      - `max_iterations` — max successful execution steps per turn (default: `10`)
      - `max_retries` — max consecutive failures before giving up (default: `3`)
      - `sandbox_timeout` — timeout in ms for code execution (default: `60_000`)
      - `binding_scope` — how long variable bindings from code execution live
        (default: `:turn`):
        - `:iteration` — bindings reset between every code execution
        - `:turn` — bindings persist across iterations within one turn, reset between turns
        - `:conversation` — bindings persist for the entire conversation (across turns)
      - `max_message_length` — max byte size of a single message added to the
        conversation (user input, code execution result, or error text). Longer
        content is truncated with a `[... truncated N bytes ...]` marker.
        Defaults to `20_000`. Set to `:infinity` to disable truncation.

    - `action_types/0` — list of action strings the LLM is allowed to respond with.
      Defaults to all four: `~w(eval_and_continue eval_and_complete return done)`.
      Override to restrict the agent - for example, a read-only agent that should
      never execute code can use `~w(return done)`.
  """

  @callback tools() :: [module()]
  @callback tool_config(tool :: atom()) :: keyword()
  @callback system_prompt() :: String.t()
  @callback output_schema() :: map()
  @callback config() :: map()
  @callback action_types() :: [String.t()]
  @optional_callbacks tools: 0,
                      tool_config: 1,
                      system_prompt: 0,
                      output_schema: 0,
                      config: 0,
                      action_types: 0

  defmacro __using__(_opts) do
    quote do
      @behaviour Legion.Agent
      @before_compile Legion.Agent

      def moduledoc do
        case @moduledoc do
          doc when is_binary(doc) and doc != "" -> doc
          _ -> raise "#{inspect(__MODULE__)} must define a @moduledoc"
        end
      end

      def tools, do: []
      def output_schema, do: %{"type" => "string"}
      def config, do: %{}
      def action_types, do: ~w(eval_and_continue eval_and_complete return done)

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {Legion, :start_link, [__MODULE__, opts]},
          restart: :transient
        }
      end

      defoverridable tools: 0,
                     output_schema: 0,
                     config: 0,
                     action_types: 0
    end
  end

  defmacro __before_compile__(env) do
    moduledoc = Module.get_attribute(env.module, :moduledoc)

    doc =
      case moduledoc do
        {_line, doc} when is_binary(doc) and doc != "" -> doc
        _ -> nil
      end

    unless doc do
      raise CompileError,
        description: "#{inspect(env.module)} must define a @moduledoc",
        file: env.file,
        line: 0
    end

    quote do
      def tool_config(_tool), do: []
    end
  end
end
