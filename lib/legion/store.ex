defmodule Legion.Store do
  @moduledoc """
  Behaviour for persisting agent conversations across restarts.

  Legion decides *when* to persist; your store decides *where*. Pass a store
  module and an agent id when starting an agent:

      {:ok, pid} = Legion.start_link(AssistantAgent, store: MyApp.AgentStore, agent_id: "user_42")

  On start, the agent calls `c:load/1` and resumes from the snapshot if one
  exists. The system prompt is regenerated fresh on every start, so prompt or
  tool changes apply to restored conversations.

  After every completed turn, the agent calls `c:save/2` **before** replying
  to the caller. A reply is a commit receipt: any turn a caller observed
  survives a crash, restart, or deploy. A crash mid-turn rolls back to the
  last completed turn.

  For Postgres users there is a ready-made adapter - see `Legion.Store.Postgres`:

      defmodule MyApp.AgentStore do
        use Legion.Store.Postgres, repo: MyApp.Repo
      end

  ## Configuring the store

  Pass `:store` per agent, or set one globally so every agent persists by default:

      config :legion, :store, MyApp.AgentStore

  A `:store` given to `start_link/2` overrides the global one.

  ## Identifying a conversation

  `:agent_id` is the key a snapshot is saved under - it names one conversation,
  not one user. A chat app with many chats per user keys by the chat; compose the
  id however you like, since Legion treats it as opaque:

      Legion.start_link(ChatAgent, agent_id: "user_42:chat_7")

  With a store in effect, omitting `:agent_id` makes Legion generate one. That
  suits a brand-new conversation: read it back with `Legion.get_agent_id/1` and
  persist the mapping if you want to resume the chat later. Pass your own id to
  resume an existing conversation. Two agents started under the same id race onto
  the same row, so route each conversation to a single process.

  Or implement the two callbacks against any storage you like:

  ## Example: hand-rolled Ecto store

      defmodule MyApp.AgentStore do
        @behaviour Legion.Store

        def load(agent_id) do
          case MyApp.Repo.get(MyApp.AgentSnapshot, agent_id) do
            nil -> :error
            row -> {:ok, :erlang.binary_to_term(row.snapshot)}
          end
        end

        def save(agent_id, snapshot) do
          MyApp.Repo.insert!(
            %MyApp.AgentSnapshot{id: agent_id, snapshot: :erlang.term_to_binary(snapshot)},
            on_conflict: {:replace, [:snapshot]},
            conflict_target: :id
          )

          :ok
        end
      end

  ## What is persisted

  The snapshot holds the conversation `:messages` (without the system prompt)
  and the `:bindings` from evaluated code (relevant with
  `binding_scope: :conversation`). Bindings are arbitrary Elixir terms -
  values like pids, references, or functions will not survive
  serialization, so keep conversation-scoped variables to plain data if you
  persist agents.
  """

  @type agent_id :: term()
  @type snapshot :: %{messages: [map()], bindings: keyword()}

  @doc "Returns the last saved snapshot for `agent_id`, or `:error` if none exists."
  @callback load(agent_id()) :: {:ok, snapshot()} | :error

  @doc "Saves the snapshot for `agent_id`. Raise on failure - the turn is not acked until this returns."
  @callback save(agent_id(), snapshot()) :: :ok
end
