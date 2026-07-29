defmodule Legion.Executor do
  @moduledoc """
  Drives the LLM thinking loop for a single agent turn.

  Given a complete message history, calls the LLM, parses its response, runs
  sandboxed code if needed, and recurses until the LLM signals completion.

  Returns the final result and updated message history so the caller can persist
  context across turns.
  """

  alias Legion.{Sandbox, Telemetry}

  @default_config %{
    model: "openai:gpt-5.4",
    max_iterations: 10,
    max_retries: 3,
    sandbox_timeout: 60_000,
    binding_scope: :turn,
    max_message_length: 20_000
  }

  @doc false
  def default_config, do: @default_config

  @message_roles %{
    system: "system",
    user: "user",
    assistant: "assistant",
    eval_result: "user",
    error: "user"
  }

  @doc """
  Builds a conversation message stamped with its `:type` and creation time
  (`:at`, milliseconds). The extra keys ride along into persisted state so
  consumers (e.g. LegionWeb) can classify messages without parsing content;
  ReqLLM ignores them.
  """
  def message(type, content) do
    %{
      role: Map.fetch!(@message_roles, type),
      type: type,
      content: content,
      at: System.system_time(:millisecond)
    }
  end

  @action_descriptions %{
    "eval_and_continue" =>
      "Execute code and continue the turn. Use when you need the result before deciding the next step.",
    "eval_and_complete" =>
      "Finish the turn with the code's result. Use when the final answer comes from executing code.",
    "return" =>
      "Finish the turn with a structured result and no code execution. Only use when the task is fully done - not to report in-progress work, ask the user something, or bail out of execution errors (fix the code and re-run instead). The result is a final answer, not a chat message: never return a status like \"starting\" or \"working on it\" - do the work first.",
    "done" =>
      "Finish the turn with no result to return. This ends your run - nothing executes after it, so only use it when everything you were asked to do is fully done. Never announce upcoming work and then pick this action; do the work first (eval_and_continue)."
  }

  defp action_schema(agent_module) do
    types = agent_module.action_types()

    description =
      types
      |> Enum.map_join("\n", fn t -> "- \"#{t}\": #{Map.fetch!(@action_descriptions, t)}" end)

    %{
      "type" => "object",
      "required" => ["action", "code", "result"],
      "additionalProperties" => false,
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => types,
          "description" => "The action to take:\n" <> description
        },
        "code" => %{
          "type" => "string",
          "description" =>
            "Elixir code to execute. Required for eval_* actions. Empty string otherwise."
        },
        "result" => enforce_no_additional_properties(agent_module.output_schema())
      }
    }
  end

  # OpenAI strict mode requires `additionalProperties: false` on every object
  # in the schema tree. Inject it recursively so users don't have to.
  defp enforce_no_additional_properties(%{"type" => "object", "properties" => props} = schema) do
    props = Map.new(props, fn {k, v} -> {k, enforce_no_additional_properties(v)} end)

    schema
    |> Map.put("properties", props)
    |> Map.put("additionalProperties", false)
  end

  defp enforce_no_additional_properties(%{"type" => "array", "items" => items} = schema) do
    Map.put(schema, "items", enforce_no_additional_properties(items))
  end

  defp enforce_no_additional_properties(schema), do: schema

  @doc """
  Runs the LLM loop against the given message history.

  `messages` must already include the system prompt and the current user message.

  Returns `{:ok, result, messages, bindings}` or `{:cancel, reason, messages, bindings}`.
  """
  def run(agent_module, messages, config, bindings \\ [], execution \\ nil) do
    config = Map.merge(@default_config, config)

    case execution do
      nil ->
        loop(agent_module, messages, config, 0, 0, bindings)

      %{phase: :awaiting_llm, iteration: i, retries: r} ->
        loop(agent_module, messages, config, i, r, bindings)

      %{phase: :completing, iteration: _i, retries: _r} ->
        {:ok, nil, messages, bindings}
    end
  end

  defp loop(agent_module, messages, config, iteration, retries, bindings) do
    if iteration >= config.max_iterations do
      {:cancel, :reached_max_iterations, messages, bindings}
    else
      Telemetry.span(
        [:legion, :iteration],
        %{agent: agent_module, iteration: iteration},
        fn -> iterate(agent_module, messages, config, iteration, retries, bindings) end
      )
    end
  end

  defp iterate(agent_module, messages, config, iteration, retries, bindings) do
    # credo:disable-for-next-line
    try do
      with {:ok, action, messages} <- call_llm(agent_module, messages, config, iteration),
           :ok <- validate_action_type(agent_module, action) do
        result =
          handle_action(agent_module, messages, config, action, iteration, retries, bindings)

        {result, %{action: action["action"]}}
      else
        {:error, reason} ->
          result =
            handle_execution_error(
              agent_module,
              messages,
              config,
              reason,
              iteration,
              retries,
              bindings
            )

          {result, %{action: nil}}
      end
    rescue
      e ->
        result =
          handle_execution_error(agent_module, messages, config, e, iteration, retries, bindings)

        {result, %{action: nil}}
    end
  end

  defp call_llm(agent_module, messages, config, iteration) do
    Telemetry.span(
      [:legion, :llm, :request],
      %{
        agent: agent_module,
        model: config.model,
        message_count: length(messages),
        iteration: iteration
      },
      fn ->
        case ReqLLM.generate_object(config.model, messages, action_schema(agent_module)) do
          {:ok, response} ->
            action = extract_object(response)
            messages = messages ++ [message(:assistant, Jason.encode!(action))]
            {{:ok, action, messages}, %{object: action}}

          {:error, reason} ->
            {{:error, "LLM request failed: #{inspect(reason)}"}, %{error: reason}}
        end
      end
    )
  end

  defp checkpoint!(config, messages, bindings, execution) do
    case config[:checkpoint] do
      nil ->
        :ok

      callback ->
        try do
          :ok =
            callback.(%{
              messages: messages,
              bindings: bindings,
              execution: execution
            })
        rescue
          error -> exit({:checkpoint_persistence_failed, error})
        end
    end
  end

  defp handle_action(
         _agent,
         messages,
         _config,
         %{"action" => "return", "result" => result},
         _i,
         _r,
         bindings
       ),
       do: {:ok, result, messages, bindings}

  defp handle_action(_agent, messages, _config, %{"action" => "done"}, _i, _r, bindings),
    do: {:ok, nil, messages, bindings}

  defp handle_action(
         agent,
         messages,
         config,
         %{"action" => eval, "code" => code},
         i,
         retries,
         bindings
       )
       when eval in ["eval_and_continue", "eval_and_complete"] and code != "" do
    # Tools that must see the answer come back to the model (e.g. HumanTool)
    # read this to reject running under a turn-ending action.
    Vault.unsafe_put(:current_action, eval)

    case eval_in_span(agent, code, config, bindings) do
      {:ok, {result, new_bindings}} ->
        new_bindings = if config.binding_scope == :iteration, do: [], else: new_bindings

        messages =
          messages ++ [message(:eval_result, format_result(result, new_bindings, config))]

        execution =
          if eval == "eval_and_continue" do
            %{phase: :awaiting_llm, iteration: i + 1, retries: 0}
          else
            %{phase: :completing, iteration: i, retries: 0}
          end

        checkpoint!(config, messages, new_bindings, execution)

        if eval == "eval_and_continue",
          do: loop(agent, messages, config, i + 1, 0, new_bindings),
          else: {:ok, result, messages, new_bindings}

      {:error, error} ->
        handle_execution_error(agent, messages, config, error, i, retries, bindings)
    end
  end

  defp handle_action(agent, messages, config, action, i, retries, bindings),
    do:
      handle_execution_error(
        agent,
        messages,
        config,
        "Unexpected action: #{inspect(action)}",
        i,
        retries,
        bindings
      )

  defp eval_in_span(agent_module, code, config, bindings) do
    Telemetry.span([:legion, :sandbox, :eval], %{agent: agent_module, code: code}, fn ->
      tools = agent_module.tools()

      allowed = tools ++ Enum.flat_map(tools, &extra_allowed_modules/1)

      case Sandbox.execute(code, config.sandbox_timeout, allowed, bindings) do
        {:ok, {value, new_bindings}} ->
          {{:ok, {value, new_bindings}}, %{success: true, result: value}}

        {:error, error} ->
          {{:error, error}, %{success: false, error: error}}
      end
    end)
  end

  defp extra_allowed_modules(tool) do
    if function_exported?(tool, :extra_allowed_modules, 0) do
      tool.extra_allowed_modules()
    else
      []
    end
  end

  defp handle_execution_error(agent_module, messages, config, error, iteration, retries, bindings) do
    if retries >= config.max_retries do
      {:cancel, :reached_max_retries, messages, bindings}
    else
      error_text = error |> format_error() |> truncate_content(config[:max_message_length])

      messages =
        messages ++
          [
            message(
              :error,
              "Code execution failed:\n\n#{error_text}\n\nPlease fix the error and try again."
            )
          ]

      next_retries = retries + 1

      checkpoint!(config, messages, bindings, %{
        phase: :awaiting_llm,
        iteration: iteration,
        retries: next_retries
      })

      loop(agent_module, messages, config, iteration, next_retries, bindings)
    end
  end

  defp validate_action_type(agent_module, %{"action" => action_type}) do
    allowed = agent_module.action_types()

    if action_type in allowed do
      :ok
    else
      {:error,
       "Action #{inspect(action_type)} is not allowed for #{inspect(agent_module)}. " <>
         "Allowed: #{inspect(allowed)}"}
    end
  end

  defp validate_action_type(_agent_module, action) do
    {:error, "Response missing required 'action' field, got: #{inspect(action)}"}
  end

  defp extract_object(%{object: object}) when is_map(object), do: object

  defp extract_object(%{message: %{tool_calls: tool_calls}}) when is_list(tool_calls) do
    ReqLLM.ToolCall.find_args(tool_calls, "structured_output") ||
      raise "LLM response contained no structured object"
  end

  defp extract_object(_response), do: raise("LLM response contained no structured object")

  defp format_result(result, bindings, config) do
    variable_names = bindings |> Keyword.keys() |> Enum.map(&"`#{&1}`")

    inspected =
      result
      |> inspect(pretty: true, limit: 1000)
      |> truncate_content(config[:max_message_length])

    base = """
    Code executed successfully. Result:
    ```
    #{inspected}
    ```
    """

    if variable_names == [] do
      base
    else
      base <> "\nAvailable variables: #{Enum.join(variable_names, ", ")}"
    end
  end

  defp format_error(message) when is_binary(message), do: message
  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(error) when is_exception(error), do: Exception.message(error)
  defp format_error(error), do: inspect(error, pretty: true, limit: 50)

  @doc false
  def truncate_content(content, :infinity), do: content

  def truncate_content(content, max)
      when is_binary(content) and is_integer(max) and byte_size(content) > max do
    binary_part(content, 0, max) <> "\n\n[... truncated #{byte_size(content) - max} bytes ...]"
  end

  def truncate_content(content, _max), do: content
end
