defmodule Legion.Store do
  @moduledoc """
  Behaviour for persisting agent conversations across restarts.

  Legion decides *when* to persist; your store decides *where*. Pass a store
  module and an agent id when starting an agent:

      {:ok, pid} = Legion.start_link(AssistantAgent, store: MyApp.AgentStore, agent_id: "user_42")

  On start, the agent calls `c:get/1` and resumes from the returned
  `Legion.Store.Conversation.State` if one exists. The system prompt is
  regenerated fresh on every start, so prompt or tool changes apply to
  restored conversations.

  After every completed turn, the agent calls `c:save/2` with a
  `Legion.Store.Conversation.State` **before** replying to the caller. A reply
  is a commit receipt: any turn a caller observed survives a crash, restart,
  or deploy. A crash mid-turn rolls back to the last completed turn.

  For Postgres users there is a ready-made adapter - see `Legion.Store.Postgres`:

      defmodule MyApp.AgentStore do
        use Legion.Store.Postgres, repo: MyApp.Repo
      end

  ## Configuring the store

  Pass `:store` per agent, or set one globally so every agent persists by default:

      config :legion, :store, MyApp.AgentStore

  A `:store` given to `start_link/2` overrides the global one. Sub-agents
  spawned from a running agent (e.g. via `Legion.Tools.AgentTool`) inherit
  the parent's store automatically. The inheritance is ambient: *any* agent
  started from within an agent's process tree picks up that store unless
  given an explicit `:store` of its own.

  ## Identifying a conversation

  `:agent_id` is the key a conversation is saved under - it names one
  conversation, not one user. A chat app with many chats per user keys by the
  chat; compose the id however you like, since Legion treats it as opaque:

      Legion.start_link(ChatAgent, agent_id: "user_42:chat_7")

  Omitting `:agent_id` makes Legion generate one. That
  suits a brand-new conversation: read it back with `Legion.get_agent_id/1` and
  persist the mapping if you want to resume the chat later. Pass your own id to
  resume an existing conversation. Two agents started under the same id race onto
  the same row, so route each conversation to a single process.

  ## Required persistence

  Stores must implement `c:get/1` and `c:save/2`.

  Stores must accept two required save payloads:

    - `Legion.Store.Conversation.State`, which holds the conversation
      `:messages` (without the system prompt) and the `:bindings` from
      evaluated code (relevant with `binding_scope: :conversation`)
    - `{:status, :running | :idle}`, which records whether the agent is
      mid-turn

  Each message carries a `:type` (`:user`, `:assistant`, `:eval_result`, or
  `:error`) and an `:at` timestamp in milliseconds, so consumers can classify
  and order messages without parsing content. Bindings are arbitrary Elixir
  terms - values like pids, references, or functions will not survive
  serialization, so keep conversation-scoped variables to plain data if you
  persist agents.

  ## Optional persistence

  Stores may also accept `Legion.Store.Conversation.Metadata` through
  `c:save/2` to record which agent module ran, under which parent
  conversation, and when.

  `use Legion.Store` provides default no-op `save/2` clauses for state,
  metadata, and status payloads. They log a warning and return `:ok`, so a
  store can opt into only the payloads it persists without breaking agent
  execution. Override `save/2` for durable persistence.

  Because metadata persistence is optional, conversations returned from
  `c:get/1` or `c:list/1` may have `metadata: nil`. `status` may also be nil
  for persisted conversations created before status was recorded. Because a
  store may record metadata or status before any conversation state is saved,
  `state` may also be nil.

  ## Reading conversations

  `c:get/1` returns the persisted conversation for one `agent_id`, or `:error`
  when the store has no row for that id.

  The optional `c:list/1` callback returns persisted conversations newest first
  for consumers that rebuild a view of past conversations from the store
  alone.
  """

  alias Legion.Store.Conversation
  alias Legion.Store.Conversation.{Metadata, State}

  @type agent_id :: term()
  @type status :: Conversation.status()
  @type conversation :: Conversation.t()
  @type payload ::
          State.t()
          | Metadata.t()
          | {:status, status()}

  @doc "Returns the persisted conversation for `agent_id`, or `:error` if none exists."
  @callback get(agent_id()) :: {:ok, conversation()} | :error

  @doc "Returns the newest `limit` persisted conversations, newest first."
  @callback list(limit :: pos_integer()) :: [conversation()]

  @doc "Saves a conversation state, status, or optional conversation metadata for `agent_id`."
  @callback save(agent_id(), payload()) :: :ok | :error

  @optional_callbacks list: 1

  defmacro __using__(_opts) do
    quote do
      @behaviour Legion.Store

      require Logger

      def save(_agent_id, %Conversation.State{}) do
        Logger.warning(
          "Store #{inspect(__MODULE__)} does not persist conversation state; override save/2 to persist this payload"
        )

        :ok
      end

      def save(_agent_id, %Conversation.Metadata{}) do
        Logger.warning(
          "Store #{inspect(__MODULE__)} does not persist conversation metadata; override save/2 to persist this payload"
        )

        :ok
      end

      def save(_agent_id, {:status, status}) when status in [:running, :idle] do
        Logger.warning(
          "Store #{inspect(__MODULE__)} does not persist conversation status; override save/2 to persist this payload"
        )

        :ok
      end

      defoverridable save: 2
    end
  end
end
