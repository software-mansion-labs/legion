defmodule Legion.AgentServer do
  @moduledoc """
  GenServer that maintains conversation history for a long-lived agent.

  Holds the message history across multiple turns. Each `call` or `cast`
  appends the user message and runs `Executor` to completion (blocking).
  """

  use GenServer

  require Logger

  alias Legion.{Executor, Telemetry}
  alias ReqLLM.Message.ContentPart

  defstruct [:agent_module, :messages, :config, :store, :agent_id, bindings: []]

  # Client API

  def start_link(agent_module, opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    {store, opts} = Keyword.pop(opts, :store)
    {agent_id, opts} = Keyword.pop(opts, :agent_id)

    store = store || Application.get_env(:legion, :store)

    if is_nil(store) and not is_nil(agent_id) do
      raise ArgumentError,
            ":agent_id requires a :store - pass one or set `config :legion, :store, MyStore`"
    end

    agent_id = if store, do: agent_id || generate_agent_id(), else: nil

    gen_opts = if name, do: [name: name], else: []
    config = resolve_config(agent_module, opts)
    GenServer.start_link(__MODULE__, {agent_module, config, store, agent_id}, gen_opts)
  end

  def call(agent, message, timeout \\ :infinity) do
    GenServer.call(agent, {:message, message}, timeout)
  end

  def cast(agent, message) do
    GenServer.cast(agent, {:message, message})
  end

  def get_messages(agent) do
    GenServer.call(agent, :get_messages)
  end

  def get_agent_id(agent) do
    GenServer.call(agent, :get_agent_id)
  end

  # Server callbacks

  @impl true
  def init({agent_module, config, store, agent_id}) do
    parent_run_id = Vault.get(:run_id)
    run_id = make_ref()

    Vault.unsafe_put(:run_id, run_id)
    Vault.unsafe_put(:parent_run_id, parent_run_id)

    for tool <- agent_module.tools() do
      Vault.unsafe_put(tool, agent_module.tool_config(tool))
    end

    system_prompt = Legion.AgentPrompt.system_prompt(agent_module, config)

    Telemetry.emit(
      [:legion, :agent, :started],
      %{system_time: System.system_time()},
      %{agent: agent_module}
    )

    {saved_messages, saved_bindings} =
      case store && store.load(agent_id) do
        {:ok, %{messages: messages, bindings: bindings}} -> {messages, bindings}
        _no_snapshot -> {[], []}
      end

    state = %__MODULE__{
      agent_module: agent_module,
      messages: [%{role: "system", content: system_prompt} | saved_messages],
      config: config,
      store: store,
      agent_id: agent_id,
      bindings: saved_bindings
    }

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    Telemetry.emit(
      [:legion, :agent, :stopped],
      %{system_time: System.system_time()},
      %{agent: state.agent_module}
    )
  end

  @impl true
  def handle_call(:get_messages, _from, state) do
    {:reply, state.messages, state}
  end

  @impl true
  def handle_call(:get_agent_id, _from, state) do
    {:reply, state.agent_id, state}
  end

  @impl true
  def handle_call({:message, message}, _from, state) do
    {reply, state} = handle_message(message, state)
    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:message, message}, state) do
    {_reply, state} = handle_message(message, state)
    {:noreply, state}
  end

  @doc """
  Normalizes `message`, appends it to the conversation, and runs the executor
  to completion. Returns `{{status, value}, new_state}`.

  Accepted `message` shapes:
    - `binary` - passed verbatim as the user message
    - `{:image, data, media_type}` - single inline image from binary data
    - `{:image_url, url}` - single image from a URL
    - `{:multipart, [ContentPart.t()]}` - mixed text/image/file content; build
      parts with `ReqLLM.Message.ContentPart.text/1`, `image/2`, `image_url/1`,
      `file/3`
    - anything else - rendered via `inspect/2`
  """
  def handle_message(message, state) do
    content = stringify(message, state.config[:max_message_length])
    conversation_scope? = Map.get(state.config, :binding_scope, :turn) == :conversation

    {status, value, final_messages, final_bindings} =
      Telemetry.span(
        [:legion, :agent, :message],
        %{agent: state.agent_module, message: content},
        fn ->
          messages = state.messages ++ [%{role: "user", content: content}]
          prev_count = Enum.count(messages, &(&1[:role] == "assistant"))

          initial_bindings = if conversation_scope?, do: state.bindings, else: []

          {status, value, messages, bindings} =
            result = Executor.run(state.agent_module, messages, state.config, initial_bindings)

          iterations = Enum.count(messages, &(&1[:role] == "assistant")) - prev_count
          {result, %{iterations: iterations, status: status, result: value, bindings: bindings}}
        end
      )

    kept_bindings = if conversation_scope?, do: final_bindings, else: []
    state = persist(%{state | messages: final_messages, bindings: kept_bindings})
    {{status, value}, state}
  end

  defp persist(%{store: nil} = state), do: state

  defp persist(state) do
    [%{role: "system"} | messages] = state.messages
    :ok = state.store.save(state.agent_id, %{messages: messages, bindings: state.bindings})
    state
  end

  defp generate_agent_id, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  defp stringify(message, max_length) when is_binary(message),
    do: Executor.truncate_content(message, max_length)

  defp stringify({:image, data, media_type}, _max_length)
       when is_binary(data) and is_binary(media_type) do
    [ContentPart.image(data, media_type)]
  end

  defp stringify({:image_url, url}, _max_length) when is_binary(url) do
    [ContentPart.image_url(url)]
  end

  defp stringify({:multipart, parts}, _max_length) when is_list(parts), do: parts

  defp stringify(message, max_length) do
    message
    |> inspect(limit: :infinity)
    |> Executor.truncate_content(max_length)
  end

  @known_config_keys ~w(binding_scope max_iterations max_message_length max_retries model sandbox_timeout)a

  defp resolve_config(agent_module, opts) do
    app_config = Application.get_env(:legion, :config, %{})
    call_config = Map.new(opts)

    merged =
      Executor.default_config()
      |> Map.merge(app_config)
      |> Map.merge(agent_module.config())
      |> Map.merge(call_config)

    unknown = Map.keys(merged) -- @known_config_keys

    if unknown != [] do
      Logger.warning("Unknown Legion config keys: #{inspect(unknown)}")
    end

    validate_max_message_length(merged)

    merged
  end

  defp validate_max_message_length(%{max_message_length: :infinity}), do: :ok

  defp validate_max_message_length(%{max_message_length: n}) when is_integer(n) and n > 0,
    do: :ok

  defp validate_max_message_length(%{max_message_length: other}) do
    raise ArgumentError,
          "expected :max_message_length to be a positive integer or :infinity, got: #{inspect(other)}"
  end

  defp validate_max_message_length(_config), do: :ok
end
