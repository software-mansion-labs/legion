defmodule Legion.Store do
  @moduledoc """
  Behaviour for persisting agent conversations across restarts.

  Legion decides *when* to persist; your store decides *where*. Pass a store
  module and an agent id when starting an agent:

      {:ok, pid} = Legion.start_link(AssistantAgent, store: MyApp.AgentStore, agent_id: "user_42")

  On start, the agent calls `c:get/1` and resumes from the returned
  `Legion.Store.Payload` when it has a `:conversation_state`. The system prompt
  is regenerated for every start, so prompt and tool changes apply to restored
  conversations.

  After every completed turn, the agent calls `c:save/1` with a payload before
  replying to the caller. A reply is a commit receipt: any observed turn
  survives a crash, restart, or deploy. A crash mid-turn rolls back to the last
  completed turn.

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

  Stores must implement `c:get/1` and `c:save/1`.

  `c:save/1` receives a `Legion.Store.Payload`. Its `:conversation_state` is a
  map containing the conversation's `:messages` (without the system prompt)
  and `:bindings` from evaluated code (relevant with
  `binding_scope: :conversation`). `:status` records whether the agent is
  mid-turn. The payload also carries the agent module, parent conversation, and
  start time when those values are known.

  Each message carries a `:type` (`:user`, `:assistant`, `:eval_result`, or
  `:error`) and an `:at` timestamp in milliseconds, so consumers can classify
  and order messages without parsing content. Bindings are arbitrary Elixir
  terms - values like pids, references, or functions will not survive
  serialization, so keep conversation-scoped variables to plain data if you
  persist agents.

  `use Legion.Store` provides a default no-op `save/1` that logs a warning.
  Override it for durable persistence.

  Payload fields other than `:agent_id` may be nil. A store can therefore
  persist identity or status before a conversation state exists.

  ## Reading conversations

  `c:get/1` returns the persisted conversation for one `agent_id`, or `:error`
  when the store has no row for that id.

  The optional `c:list/1` callback returns persisted conversations newest first
  for consumers that rebuild a view of past conversations from the store
  alone.
  """

  alias Legion.Store.Payload

  @type agent_id :: term()
  @type status :: Payload.status()
  @type payload :: Payload.t()

  @doc "Returns the persisted conversation for `agent_id`, or `:error` if none exists."
  @callback get(agent_id()) :: {:ok, payload()} | :error

  @doc "Returns the newest `limit` persisted conversations, newest first."
  @callback list(limit :: pos_integer()) :: [payload()]

  @doc "Saves a conversation payload."
  @callback save(payload()) :: :ok | :error
end
