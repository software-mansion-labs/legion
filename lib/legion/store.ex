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
