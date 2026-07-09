defmodule Legion.AgentServerTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Legion.Test.Support.MathAgent
  alias ReqLLM.Message.ContentPart

  defmodule ConversationBindingsAgent do
    @moduledoc "Agent with bindings persisted across the whole conversation."
    use Legion.Agent

    def config, do: %{binding_scope: :conversation}
  end

  defmodule ConfiguredAgent do
    @moduledoc "Test agent with custom config."
    use Legion.Agent

    def config, do: %{model: "agent-model"}
    def tools, do: [Legion.Test.Support.MathTool]
  end

  setup :set_mimic_global

  @moduletag capture_log: true

  defp llm_response(result) do
    {:ok,
     %ReqLLM.Response{
       id: "test",
       model: "test",
       context: nil,
       object: %{"action" => "return", "code" => "", "result" => result}
     }}
  end

  defp llm_eval_response(code) do
    {:ok,
     %ReqLLM.Response{
       id: "test",
       model: "test",
       context: nil,
       object: %{"action" => "eval_and_complete", "code" => code, "result" => ""}
     }}
  end

  describe "get_messages/1" do
    test "returns conversation history from a running agent" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      {:ok, pid} = Legion.start_link(MathAgent)
      {:ok, _} = Legion.call(pid, "What is the capital of France?")

      messages = Legion.get_messages(pid)

      assert [
               %{role: "system", content: _system},
               %{role: "user", content: "What is the capital of France?"},
               %{role: "assistant"} | _
             ] = messages
    end
  end

  describe "config validation" do
    test "warns about unknown config keys" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("ok")
      end)

      log =
        capture_log(fn ->
          {:ok, pid} = Legion.start_link(MathAgent, bogus_key: true)
          {:ok, _} = Legion.call(pid, "hi")
        end)

      assert log =~ "Unknown Legion config keys: [:bogus_key]"
    end
  end

  describe "config resolution" do
    test "call-time opts override agent config" do
      test_pid = self()

      stub(ReqLLM, :generate_object, fn model, _messages, _schema ->
        send(test_pid, {:model_used, model})
        llm_response("ok")
      end)

      {:ok, pid} = Legion.start_link(ConfiguredAgent, model: "call-model")
      {:ok, _} = Legion.call(pid, "hi")

      assert_receive {:model_used, "call-model"}
    end

    test "agent config overrides application config" do
      Application.put_env(:legion, :config, %{model: "app-model"})

      on_exit(fn -> Application.delete_env(:legion, :config) end)

      test_pid = self()

      stub(ReqLLM, :generate_object, fn model, _messages, _schema ->
        send(test_pid, {:model_used, model})
        llm_response("ok")
      end)

      {:ok, pid} = Legion.start_link(ConfiguredAgent)
      {:ok, _} = Legion.call(pid, "hi")

      assert_receive {:model_used, "agent-model"}
    end
  end

  describe "terminate/2" do
    test "emits stopped event when agent terminates" do
      stub(ReqLLM, :generate_object, fn _, _, _ -> llm_response("ok") end)

      test_pid = self()
      handler_id = "test-terminate-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:legion, :agent, :stopped],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:stopped, metadata.agent})
        end,
        nil
      )

      {:ok, pid} = Legion.start_link(MathAgent)
      GenServer.stop(pid)

      assert_receive {:stopped, Legion.Test.Support.MathAgent}
      :telemetry.detach(handler_id)
    end
  end

  defp capture_user_content(test_pid) do
    stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
      user_msg = Enum.find(messages, &(&1[:role] == "user"))
      send(test_pid, {:user_content, user_msg[:content]})
      llm_response("ok")
    end)
  end

  describe "multipart messages" do
    test "passes a text + image part list through to the LLM unchanged" do
      capture_user_content(self())

      parts = [
        ContentPart.text("Describe this image."),
        ContentPart.image(<<1, 2, 3>>, "image/png")
      ]

      assert {:ok, "ok"} = Legion.execute(MathAgent, {:multipart, parts})
      assert_received {:user_content, ^parts}
    end

    test "supports text + image_url parts" do
      capture_user_content(self())

      parts = [
        ContentPart.text("What is in this picture?"),
        ContentPart.image_url("https://example.com/photo.png")
      ]

      assert {:ok, "ok"} = Legion.execute(MathAgent, {:multipart, parts})
      assert_received {:user_content, ^parts}
    end

    test "supports a text-only part list" do
      capture_user_content(self())

      parts = [ContentPart.text("hello")]

      assert {:ok, "ok"} = Legion.execute(MathAgent, {:multipart, parts})
      assert_received {:user_content, ^parts}
    end

    test "supports an empty parts list" do
      capture_user_content(self())

      assert {:ok, "ok"} = Legion.execute(MathAgent, {:multipart, []})
      assert_received {:user_content, []}
    end
  end

  describe "image shorthand messages" do
    test "wraps {:image, data, media_type} into a single image ContentPart" do
      capture_user_content(self())

      data = <<1, 2, 3>>
      expected = [ContentPart.image(data, "image/png")]

      assert {:ok, "ok"} = Legion.execute(MathAgent, {:image, data, "image/png"})
      assert_received {:user_content, ^expected}
    end

    test "wraps {:image_url, url} into a single image_url ContentPart" do
      capture_user_content(self())

      url = "https://example.com/photo.png"
      expected = [ContentPart.image_url(url)]

      assert {:ok, "ok"} = Legion.execute(MathAgent, {:image_url, url})
      assert_received {:user_content, ^expected}
    end
  end

  describe "non-binary messages" do
    defmodule SampleStruct do
      defstruct [:id, :name]
    end

    test "structs are rendered via inspect" do
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
        user_msg = Enum.find(messages, &(&1[:role] == "user"))
        send(test_pid, {:user_content, user_msg[:content]})
        llm_response("ok")
      end)

      assert {:ok, "ok"} = Legion.execute(MathAgent, %SampleStruct{id: 7, name: "ada"})

      assert_received {:user_content, content}
      assert content == inspect(%SampleStruct{id: 7, name: "ada"}, limit: :infinity)
    end

    test "maps are rendered via inspect" do
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
        user_msg = Enum.find(messages, &(&1[:role] == "user"))
        send(test_pid, {:user_content, user_msg[:content]})
        llm_response("ok")
      end)

      assert {:ok, "ok"} = Legion.execute(MathAgent, %{id: 1, name: "x"})

      assert_received {:user_content, content}
      assert content == inspect(%{id: 1, name: "x"}, limit: :infinity)
    end

    test "terms containing PIDs do not crash the GenServer" do
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
        user_msg = Enum.find(messages, &(&1[:role] == "user"))
        send(test_pid, {:user_content, user_msg[:content]})
        llm_response("ok")
      end)

      {:ok, pid} = Legion.start_link(MathAgent)
      assert {:ok, "ok"} = Legion.call(pid, %{pid: self()})
      assert Process.alive?(pid)

      assert_received {:user_content, content}
      assert content =~ inspect(self())
    end
  end

  describe "max_message_length" do
    test "truncates binary user input longer than the limit" do
      capture_user_content(self())

      {:ok, pid} = Legion.start_link(MathAgent, max_message_length: 100)
      {:ok, _} = Legion.call(pid, String.duplicate("a", 5_000))

      assert_received {:user_content, content}
      assert String.starts_with?(content, String.duplicate("a", 100))
      assert content =~ "[... truncated 4900 bytes ...]"
    end

    test "passes binary user input shorter than the limit through unchanged" do
      capture_user_content(self())

      {:ok, pid} = Legion.start_link(MathAgent, max_message_length: 100)
      {:ok, _} = Legion.call(pid, "hello")

      assert_received {:user_content, "hello"}
    end

    test "does not touch multipart content even when parts are large" do
      capture_user_content(self())

      parts = [ContentPart.text(String.duplicate("a", 5_000))]

      {:ok, pid} = Legion.start_link(MathAgent, max_message_length: 100)
      {:ok, _} = Legion.call(pid, {:multipart, parts})

      assert_received {:user_content, ^parts}
    end

    test ":infinity disables truncation" do
      capture_user_content(self())

      big = String.duplicate("a", 5_000)

      {:ok, pid} = Legion.start_link(MathAgent, max_message_length: :infinity)
      {:ok, _} = Legion.call(pid, big)

      assert_received {:user_content, ^big}
    end

    test "nil raises ArgumentError" do
      assert_raise ArgumentError,
                   ~r/expected :max_message_length to be a positive integer or :infinity/,
                   fn ->
                     Legion.start_link(MathAgent, max_message_length: nil)
                   end
    end

    test "zero raises ArgumentError" do
      assert_raise ArgumentError,
                   ~r/expected :max_message_length to be a positive integer or :infinity/,
                   fn ->
                     Legion.start_link(MathAgent, max_message_length: 0)
                   end
    end

    test "per-agent config overrides application config" do
      Application.put_env(:legion, :config, %{max_message_length: 10})
      on_exit(fn -> Application.delete_env(:legion, :config) end)

      capture_user_content(self())

      {:ok, pid} = Legion.start_link(MathAgent, max_message_length: 1_000)
      {:ok, _} = Legion.call(pid, String.duplicate("a", 50))

      assert_received {:user_content, content}
      assert byte_size(content) == 50
    end

    test "application config applies when no per-agent override is given" do
      Application.put_env(:legion, :config, %{max_message_length: 10})
      on_exit(fn -> Application.delete_env(:legion, :config) end)

      capture_user_content(self())

      {:ok, pid} = Legion.start_link(MathAgent)
      {:ok, _} = Legion.call(pid, String.duplicate("a", 50))

      assert_received {:user_content, content}
      assert String.starts_with?(content, String.duplicate("a", 10))
      assert content =~ "[... truncated 40 bytes ...]"
    end

    test "default of 20_000 applies when no override is given anywhere" do
      Application.delete_env(:legion, :config)
      on_exit(fn -> Application.delete_env(:legion, :config) end)

      capture_user_content(self())

      {:ok, pid} = Legion.start_link(MathAgent)
      {:ok, _} = Legion.call(pid, String.duplicate("a", 25_000))

      assert_received {:user_content, content}
      assert String.starts_with?(content, String.duplicate("a", 20_000))
      assert content =~ "[... truncated 5000 bytes ...]"
    end
  end

  describe "cast/2" do
    test "processes message and updates state without blocking" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      {:ok, pid} = Legion.start_link(MathAgent)
      assert :ok = Legion.cast(pid, "What is the capital of France?")

      Process.sleep(100)

      messages = Legion.get_messages(pid)

      assert [
               %{role: "system"},
               %{role: "user", content: "What is the capital of France?"},
               %{role: "assistant"} | _
             ] = messages
    end
  end

  describe "named registration" do
    test "agent can be started with a registered name" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("42")
      end)

      {:ok, _pid} = Legion.start_link(MathAgent, name: :test_named_agent)
      assert {:ok, "42"} = Legion.call(:test_named_agent, "What is 42?")
    end
  end

  defmodule MemoryStore do
    @behaviour Legion.Store

    def start_link, do: Agent.start_link(fn -> %{} end, name: __MODULE__)

    def load(agent_id), do: Agent.get(__MODULE__, &Map.fetch(&1, agent_id))

    def save(agent_id, snapshot) do
      Agent.update(__MODULE__, &Map.put(&1, agent_id, snapshot))
    end
  end

  describe "persistence" do
    setup do
      start_supervised!(%{id: MemoryStore, start: {MemoryStore, :start_link, []}})
      :ok
    end

    test "saves a snapshot before the caller receives its reply" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "receipt")
      {:ok, _} = Legion.call(pid, "What is the capital of France?")

      assert {:ok, %{messages: messages, bindings: []}} = MemoryStore.load("receipt")

      assert [
               %{role: "user", content: "What is the capital of France?"},
               %{role: "assistant"} | _
             ] = messages

      refute Enum.any?(messages, &(&1.role == "system"))
    end

    test "a one-off execute/3 persists its snapshot before stopping" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      {:ok, _} =
        Legion.execute(MathAgent, "What is the capital of France?",
          store: MemoryStore,
          agent_id: "one-off"
        )

      assert {:ok, %{messages: [%{role: "user"}, %{role: "assistant"} | _]}} =
               MemoryStore.load("one-off")
    end

    test "does not persist bindings under the default :turn scope" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_eval_response("x = 42")
      end)

      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "turn-bindings")
      {:ok, 42} = Legion.call(pid, "set x")

      assert {:ok, %{bindings: []}} = MemoryStore.load("turn-bindings")
    end

    test "restores the conversation under a fresh system prompt after a restart" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "restore")
      {:ok, _} = Legion.call(pid, "What is the capital of France?")
      GenServer.stop(pid)

      {:ok, revived} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "restore")

      assert [
               %{role: "system"},
               %{role: "user", content: "What is the capital of France?"},
               %{role: "assistant"} | _
             ] = Legion.get_messages(revived)
    end

    test "restores conversation-scoped bindings after a restart" do
      stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
        assistant_count = Enum.count(messages, &(&1[:role] == "assistant"))

        if assistant_count == 0 do
          llm_eval_response("x = 42")
        else
          llm_eval_response("x + 1")
        end
      end)

      {:ok, pid} =
        Legion.start_link(ConversationBindingsAgent, store: MemoryStore, agent_id: "bindings")

      {:ok, 42} = Legion.call(pid, "set x")
      GenServer.stop(pid)

      {:ok, revived} =
        Legion.start_link(ConversationBindingsAgent, store: MemoryStore, agent_id: "bindings")

      assert {:ok, 43} = Legion.call(revived, "use x")
    end

    test "generates an agent_id when a store is given without one" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore)
      agent_id = Legion.get_agent_id(pid)

      assert is_binary(agent_id)
      {:ok, _} = Legion.call(pid, "What is the capital of France?")
      assert {:ok, _snapshot} = MemoryStore.load(agent_id)
    end

    test "uses a store configured globally, needing only an agent_id" do
      Application.put_env(:legion, :store, MemoryStore)
      on_exit(fn -> Application.delete_env(:legion, :store) end)

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      {:ok, pid} = Legion.start_link(MathAgent, agent_id: "global-store")
      {:ok, _} = Legion.call(pid, "What is the capital of France?")

      assert {:ok, _snapshot} = MemoryStore.load("global-store")
    end

    test "get_agent_id/1 returns nil without a store" do
      {:ok, pid} = Legion.start_link(MathAgent)
      assert Legion.get_agent_id(pid) == nil
    end

    test "raises when :agent_id is given without a :store" do
      assert_raise ArgumentError, ~r/:agent_id requires a :store/, fn ->
        Legion.start_link(MathAgent, agent_id: "orphan")
      end
    end
  end

  describe "binding_scope" do
    test "bindings do not persist across turns by default (:turn)" do
      stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
        assistant_count = Enum.count(messages, &(&1[:role] == "assistant"))

        if assistant_count == 0 do
          llm_eval_response("x = 42")
        else
          llm_eval_response("x + 1")
        end
      end)

      {:ok, pid} = Legion.start_link(MathAgent)
      {:ok, 42} = Legion.call(pid, "set x")

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:cancel, :reached_max_retries} = Legion.call(pid, "use x")
      end)
    end

    test "bindings persist across turns with :conversation" do
      stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
        assistant_count = Enum.count(messages, &(&1[:role] == "assistant"))

        if assistant_count == 0 do
          llm_eval_response("x = 42")
        else
          llm_eval_response("x + 1")
        end
      end)

      {:ok, pid} = Legion.start_link(ConversationBindingsAgent)
      {:ok, 42} = Legion.call(pid, "set x")
      assert {:ok, 43} = Legion.call(pid, "use x")
    end

    test "system prompt reflects binding_scope resolved from start_link opts, not agent.config()" do
      {:ok, pid} = Legion.start_link(MathAgent, binding_scope: :conversation)
      [%{role: "system", content: system_prompt} | _] = Legion.get_messages(pid)

      assert system_prompt =~ "Variables also persist across turns"
    end

    test "system prompt reflects binding_scope resolved from Application config" do
      Application.put_env(:legion, :config, %{binding_scope: :iteration})
      on_exit(fn -> Application.delete_env(:legion, :config) end)

      {:ok, pid} = Legion.start_link(MathAgent)
      [%{role: "system", content: system_prompt} | _] = Legion.get_messages(pid)

      assert system_prompt =~ "Variables do not persist."
    end

    test "custom system_prompt/0 override wins over the default" do
      defmodule CustomPromptAgent do
        @moduledoc "Agent with custom system prompt."
        use Legion.Agent

        def system_prompt, do: "completely custom prompt"
      end

      {:ok, pid} = Legion.start_link(CustomPromptAgent, binding_scope: :conversation)
      [%{role: "system", content: system_prompt} | _] = Legion.get_messages(pid)

      assert system_prompt == "completely custom prompt"
    end
  end
end
