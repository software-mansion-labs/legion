defmodule Legion do
  @external_resource "README.md"
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC -->")
             |> Enum.fetch!(1)

  alias Legion.AgentServer

  @doc """
  Runs an agent on a single task and returns the result.

  Starts a temporary agent process, blocks until the task completes, then stops it.
  Accepts the same `opts` as `start_link/2`, so a one-off run can resume and
  persist a conversation by passing `:store` and `:agent_id`. Passing `:store`
  overrides the globally configured store for this agent; see `Legion.Store`.

  ## Examples

      {:ok, summary} = Legion.execute(ResearchAgent, "Summarize the Elixir getting started guide")
      {:cancel, :reached_max_iterations} = Legion.execute(ResearchAgent, "impossible task")
      {:ok, reply} = Legion.execute(ChatAgent, "next question", store: MyApp.AgentStore, agent_id: "user_42:chat_7")
  """
  def execute(agent_module, task, opts \\ []) do
    {:ok, pid} = AgentServer.start_link(agent_module, opts)
    result = AgentServer.call(pid, task)
    GenServer.stop(pid)
    result
  end

  @doc """
  Starts a long-lived agent process.

  ## Options
    - `:name` - register the process under a name
    - `:store`, `:agent_id` - persist the conversation across restarts; see `Legion.Store`.
      A store set globally with `config :legion, :store, MyApp.AgentStore` applies to
      every agent, so you need only pass `:agent_id`. If a store is in effect but no
      `:agent_id` is given, Legion generates one - read it back with `get_agent_id/1`.
    - Any config overrides (`:model`, `:max_iterations`, etc.)

  ## Examples

      {:ok, pid} = Legion.start_link(AssistantAgent)
      {:ok, pid} = Legion.start_link(AssistantAgent, name: MyAssistant, model: "openai:gpt-4o")
      {:ok, pid} = Legion.start_link(ChatAgent, store: MyApp.AgentStore, agent_id: "user_42:chat_7")
      {:ok, pid} = Legion.start_link(ChatAgent, agent_id: "user_42:chat_7")   # store from app config
  """
  def start_link(agent_module, opts \\ []) do
    AgentServer.start_link(agent_module, opts)
  end

  @doc """
  Sends a message to a running agent and waits for the result.

  ## Examples

      {:ok, pid} = Legion.start_link(AssistantAgent)
      {:ok, answer} = Legion.call(pid, "What is the capital of France?")
      {:ok, follow_up} = Legion.call(pid, "And its population?")
  """
  def call(pid, message, timeout \\ :infinity) do
    AgentServer.call(pid, message, timeout)
  end

  @doc """
  Sends a message to a running agent without waiting for a result.

  ## Examples

      {:ok, pid} = Legion.start_link(ReportAgent)
      Legion.cast(pid, "Generate the weekly report and email it")
  """
  def cast(pid, message) do
    AgentServer.cast(pid, message)
  end

  @doc """
  Returns the conversation history from a running agent.

  ## Examples

      {:ok, pid} = Legion.start_link(AssistantAgent)
      {:ok, _} = Legion.call(pid, "Hello")
      messages = Legion.get_messages(pid)
  """
  def get_messages(pid) do
    AgentServer.get_messages(pid)
  end

  @doc """
  Returns the id of a running agent. Always set - Legion generates one when
  none is passed.

  When a store is configured but you let Legion generate the id, capture it
  with this to resume the same conversation on a later start.

  ## Examples

      {:ok, pid} = Legion.start_link(ChatAgent)
      agent_id = Legion.get_agent_id(pid)
  """
  def get_agent_id(pid) do
    AgentServer.get_agent_id(pid)
  end

  @doc """
  Returns whether `pid` is alive on this node. Non-pid values return `false`.

  Use `lookup/1` to resolve an `agent_id` to its currently registered process
  before checking it.

  ## Examples

      case Legion.lookup("user_42:chat_7") do
        {:ok, pid} -> Legion.running?(pid)
        :error -> false
      end
  """
  def running?(pid) when is_pid(pid) do
    node(pid) == node() and Process.alive?(pid)
  rescue
    # A pid deserialized from a previous VM incarnation is not a local pid,
    # for which Process.alive?/1 raises.
    ArgumentError -> false
  end

  def running?(_other), do: false

  @doc """
  Looks up the live process for an agent id.

  Uses `Legion.AgentRegistry` as the runtime source of truth for the
  `agent_id -> pid` mapping. Returns `{:ok, pid}` when the agent is currently
  registered, or `:error` when no live process is registered for `agent_id`.

  ## Examples

      {:ok, pid} = Legion.lookup("user_42:chat_7")
      :error = Legion.lookup("missing_agent_id")
  """
  def lookup(agent_id) do
    case Registry.lookup(Legion.AgentRegistry, agent_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Resumes a persisted conversation.

  Loads the persisted conversation with `get/1` to determine its agent module,
  then returns the process registered for `agent_id` if it is still running.
  If no live process is registered, starts the persisted agent module under the
  same `agent_id` and returns its pid immediately. The new process restores the
  conversation and continues execution in the background. It resumes from a
  saved checkpoint when one exists; otherwise it starts a new executor loop
  with the restored history.

  `opts` are passed through to `start_link/2`.

  Pass `:store` or configure one globally. Raises if `get/1` does not return a
  `Legion.Store.Payload` containing an agent module for `agent_id`.

  ## Examples

      {:ok, pid} = Legion.resume("user_42:chat_7")
      {:ok, pid} = Legion.resume("user_42:chat_7", store: MyApp.AgentStore)
  """
  def resume(agent_id, opts \\ []) do
    store = store!(opts, :resume)

    agent_module =
      case store.get(agent_id) do
        {:ok, %Legion.Store.Payload{agent_module: agent_module}} when not is_nil(agent_module) ->
          agent_module

        _ ->
          raise ArgumentError,
                "no run recorded for agent_id #{inspect(agent_id)} in #{inspect(store)}"
      end

    with {:ok, pid} <- lookup(agent_id), true <- running?(pid) do
      {:ok, pid}
    else
      _ -> start_link(agent_module, Keyword.merge(opts, agent_id: agent_id, start_mode: :resume))
    end
  end

  @doc """
  Recovers an interrupted persisted root run and waits for it to finish.

  The stored payload must have `status: :running` and no `parent_agent_id`.
  `recover/2` starts a temporary agent process, waits without a timeout while
  it drives the interrupted execution to completion, then stops that process.
  Unlike `resume/2`, it does not revive the conversation as a live agent.

  The executor result is not returned. `:ok` means only that the temporary
  process stopped normally, including when the executor cancelled the run.

  Pass `:store` or configure one globally. Other options are passed through to
  `start_link/2`. Returns:

    - `:ok` when the temporary process stops normally
    - `{:error, reason}` when the temporary process stops abnormally
    - `{:error, :already_running}` when a live process is registered for `agent_id`
    - `{:error, :not_recoverable}` when the stored payload is not an interrupted root run

  Raises when no store is available, when the store has no payload for
  `agent_id`, or when the payload has no `agent_module`.

  ## Examples

      :ok = Legion.recover("user_42:chat_7", store: MyApp.AgentStore)

      {:error, :already_running} =
        Legion.recover("active_chat", store: MyApp.AgentStore)

      {:error, :not_recoverable} =
        Legion.recover("completed_chat", store: MyApp.AgentStore)
  """
  def recover(agent_id, opts \\ []) do
    store = store!(opts, :recover)

    with {:ok, pid} <- lookup(agent_id), true <- running?(pid) do
      {:error, :already_running}
    else
      _ -> recover_stored_agent(store, agent_id, opts)
    end
  end

  defp store!(opts, operation) do
    Keyword.get(opts, :store) || Vault.get(:store) || Application.get_env(:legion, :store) ||
      raise ArgumentError,
            "#{operation}/2 requires a :store - pass one or set `config :legion, :store, MyStore`"
  end

  defp recover_stored_agent(store, agent_id, opts) do
    case store.get(agent_id) do
      {:ok,
       %Legion.Store.Payload{
         agent_module: agent_module,
         status: :running,
         parent_agent_id: nil
       }}
      when not is_nil(agent_module) ->
        with {:ok, pid} <- lookup(agent_id), true <- running?(pid) do
          {:error, :already_running}
        else
          _ ->
            {:ok, {_pid, ref}} =
              AgentServer.start_monitor(
                agent_module,
                Keyword.merge(opts, agent_id: agent_id, store: store, start_mode: :recover)
              )

            receive do
              {:DOWN, ^ref, :process, _pid, :normal} -> :ok
              {:DOWN, ^ref, :process, _pid, reason} -> {:error, reason}
            end
        end

      {:ok, %Legion.Store.Payload{agent_module: nil}} ->
        raise ArgumentError,
              "no run recorded for agent_id #{inspect(agent_id)} in #{inspect(store)}"

      {:ok, %Legion.Store.Payload{}} ->
        {:error, :not_recoverable}

      :error ->
        raise ArgumentError,
              "no run recorded for agent_id #{inspect(agent_id)} in #{inspect(store)}"
    end
  end

  @doc """
  Runs multiple agent tasks concurrently and collects results.

  Returns `{:ok, results}` if all succeed, or the first `{:cancel, reason}`.

  ## Examples

      # Run two agents in parallel
      {:ok, [research, analysis]} =
        Legion.parallel([
          {ResearchAgent, "Find recent Elixir blog posts"},
          {AnalysisAgent, "Summarize market trends"}
        ])

      # With a timeout (in milliseconds)
      {:ok, results} =
        Legion.parallel(
          [{FastAgent, "task 1"}, {FastAgent, "task 2"}],
          30_000
        )
  """
  def parallel(tasks, timeout \\ :infinity) when is_list(tasks) do
    tasks
    |> Enum.map(fn {agent, task} -> Task.async(fn -> execute(agent, task) end) end)
    |> Task.await_many(timeout)
    |> collect_results()
  end

  @doc """
  Runs agent tasks sequentially, threading each result to the next step.

  Each step is `{agent, task}` where `task` is a string or a function
  that receives the previous result and returns a task string.

  Halts early if any step returns `{:cancel, reason}`.

  ## Examples

      # Static tasks — each runs independently
      {:ok, final} =
        Legion.pipeline([
          {ResearchAgent, "Find info about Elixir OTP"},
          {WriterAgent, "Write a blog post about OTP"}
        ])

      # Thread results — each step receives the previous result
      {:ok, post} =
        Legion.pipeline([
          {ResearchAgent, "Find recent Elixir news"},
          {WriterAgent, fn research -> "Write a summary based on: \#{research}" end},
          {EditorAgent, fn draft -> "Polish this draft: \#{draft}" end}
        ])
  """
  def pipeline(steps) when is_list(steps) do
    Enum.reduce_while(steps, {:ok, nil}, fn
      {agent, task}, _acc when is_binary(task) ->
        continue_or_halt(execute(agent, task))

      {agent, fun}, {:ok, prev} when is_function(fun, 1) ->
        continue_or_halt(execute(agent, fun.(prev)))

      {_agent, task}, _acc ->
        raise ArgumentError,
              "expected task to be a binary or a function/1, got: #{inspect(task)}"
    end)
  end

  @doc """
  Chains an agent task after a previous result.

  Useful for piping from `parallel/2` or `pipeline/1`.

  ## Examples

      # Chain after parallel
      Legion.parallel([
        {ResearchAgent, "Find Elixir news"},
        {ResearchAgent, "Find Erlang news"}
      ])
      |> Legion.then(WriterAgent, fn results ->
        "Summarize these findings: \#{inspect(results)}"
      end)

      # Passes through cancellations
      {:cancel, reason} |> Legion.then(WriterAgent, fn _ -> "ignored" end)
      #=> {:cancel, reason}
  """
  def then({:ok, result}, agent, fun) when is_function(fun, 1) do
    execute(agent, fun.(result))
  end

  def then({:cancel, _} = cancelled, _agent, _fun), do: cancelled

  defp continue_or_halt({:ok, _} = ok), do: {:cont, ok}
  defp continue_or_halt({:cancel, _} = cancel), do: {:halt, cancel}

  defp collect_results(results) do
    case Enum.find(results, &match?({:cancel, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, v} -> v end)}
      cancel -> cancel
    end
  end
end
