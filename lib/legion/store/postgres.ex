defmodule Legion.Store.Postgres do
  @moduledoc """
  A ready-made `Legion.Store` backed by Postgres, through your existing Ecto repo.

  Legion does not depend on Ecto - the generated store only calls
  `repo.query!/2` at runtime, so it works with any `Ecto.Repo` on
  `Ecto.Adapters.Postgres` that your application already runs.

  ## Usage

  Define a store module:

      defmodule MyApp.AgentStore do
        use Legion.Store.Postgres, repo: MyApp.Repo
      end

  Create the table in a migration:

      defmodule MyApp.Repo.Migrations.AddLegionAgents do
        use Ecto.Migration

        def change do
          create table(:legion_agents, primary_key: false) do
            add :agent_id, :text, primary_key: true
            add :snapshot, :binary, null: false
            timestamps(type: :timestamptz)
          end
        end
      end

  Then start agents with it:

      {:ok, pid} = Legion.start_link(AssistantAgent, store: MyApp.AgentStore, agent_id: "user_42")

  ## Options

    - `:repo` (required) - your Ecto repo module
    - `:table` - the table name, defaults to `"legion_agents"`

  Agent ids must be strings. Snapshots are stored as `:erlang.term_to_binary/1`
  blobs - readable only from Elixir, one row per agent, upserted on every turn.
  """

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    table = Keyword.get(opts, :table, "legion_agents")

    select_sql = "SELECT snapshot FROM #{table} WHERE agent_id = $1"

    upsert_sql = """
    INSERT INTO #{table} (agent_id, snapshot, inserted_at, updated_at)
    VALUES ($1, $2, now(), now())
    ON CONFLICT (agent_id) DO UPDATE SET snapshot = EXCLUDED.snapshot, updated_at = now()
    """

    quote do
      @behaviour Legion.Store

      @impl Legion.Store
      # sobelow_skip ["Misc.BinToTerm"]
      def load(agent_id) when is_binary(agent_id) do
        case unquote(repo).query!(unquote(select_sql), [agent_id]) do
          %{rows: [[snapshot]]} -> {:ok, :erlang.binary_to_term(snapshot)}
          %{rows: []} -> :error
        end
      end

      @impl Legion.Store
      def save(agent_id, snapshot) when is_binary(agent_id) do
        unquote(repo).query!(unquote(upsert_sql), [agent_id, :erlang.term_to_binary(snapshot)])
        :ok
      end
    end
  end
end
