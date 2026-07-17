defmodule Legion.Store do
  @moduledoc """
  Behaviour for persisting agent conversations across restarts.

  Legion decides *when* to persist; your store decides *where*. Pass a store
  module and an agent id when starting an agent:

      {:ok, pid} = Legion.start_link(AssistantAgent, store: MyApp.AgentStore, agent_id: "user_42")

  On start, the agent calls `c:get/1` and resumes from the returned
  `Legion.Store.ConversationState` if one exists. The system prompt is
  regenerated fresh on every start, so prompt or tool changes apply to
  restored conversations.

  After every completed turn, the agent calls `c:save/2` with a
  `Legion.Store.ConversationState` **before** replying to the caller. A reply
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

  `:agent_id` is the key a snapshot is saved under - it names one conversation,
  not one user. A chat app with many chats per user keys by the chat;
  compose the id however you like, since Legion treats it as opaque:

      Legion.start_link(ChatAgent, agent_id: "user_42:chat_7")

  Omitting `:agent_id` makes Legion generate one. That
  suits a brand-new conversation: read it back with `Legion.get_agent_id/1` and
  persist the mapping if you want to resume the chat later. Pass your own id to
  resume an existing conversation. Two agents started under the same id race onto
  the same row, so route each conversation to a single process.

  ## Required persistence

  Stores must implement `c:get/1` and `c:save/2`.

  The required save payload is `Legion.Store.ConversationState`, which holds
  the conversation `:messages` (without the system prompt) and the `:bindings`
  from evaluated code (relevant with `binding_scope: :conversation`). Each
  message carries a `:type` (`:user`, `:assistant`, `:eval_result`, or
  `:error`) and an `:at` timestamp in milliseconds, so consumers can classify
  and order messages without parsing content. Bindings are arbitrary Elixir
  terms - values like pids, references, or functions will not survive
  serialization, so keep conversation-scoped variables to plain data if you
  persist agents.

  ## Optional persistence

  Stores may also accept `Legion.Store.ConversationMetadata` through
  `c:save/2` to record which agent module ran, under which parent
  conversation, and when.

  Stores may also accept `{:status, :running | :idle}` through `c:save/2` to
  record whether the agent is mid-turn.

  Because metadata and status persistence are optional, snapshots returned
  from `c:get/1` or `c:list/1` may have `metadata: nil` or `status: nil`.
  Because a store may record optional data before any conversation state is
  saved, `state` may also be nil.

  ## Reading conversations

  `c:get/1` returns the persisted snapshot for one `agent_id`, or `:error`
  when the store has no row for that id.

  The optional `c:list/1` callback returns persisted snapshots newest first
  for consumers that rebuild a view of past conversations from the store
  alone.
  """

  @type agent_id :: term()
  @type status :: :idle | :running
  @type snapshot :: {
          agent_id :: agent_id(),
          metadata :: Legion.Store.ConversationMetadata.t() | nil,
          status :: status() | nil,
          state :: Legion.Store.ConversationState.t() | nil
        }
  @type payload ::
          Legion.Store.ConversationState.t()
          | Legion.Store.ConversationMetadata.t()
          | {:status, status()}

  @doc "Returns the persisted snapshot for `agent_id`, or `:error` if none exists."
  @callback get(agent_id()) :: {:ok, snapshot()} | :error

  @doc "Returns the newest `limit` persisted snapshots, newest first."
  @callback list(limit :: pos_integer()) :: [snapshot()]

  @doc "Saves a conversation state, conversation metadata, or status payload for `agent_id`."
  @callback save(agent_id(), payload()) :: :ok

  @optional_callbacks list: 1
end
