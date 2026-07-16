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

  Create the table in a migration with `Legion.Store.Postgres.Migration`:

      defmodule MyApp.Repo.Migrations.AddLegionAgents do
        use Ecto.Migration

        def up, do: Legion.Store.Postgres.Migration.up()
        def down, do: Legion.Store.Postgres.Migration.down()
      end

  Then start agents with it:

      {:ok, pid} = Legion.start_link(AssistantAgent, store: MyApp.AgentStore, agent_id: "user_42")

  ## Options

    - `:repo` (required) - your Ecto repo module
    - `:table` - the table name, defaults to `"legion_agents"`

  Agent ids must be strings. Snapshots are stored as `:erlang.term_to_binary/1`
  blobs - readable only from Elixir, one row per conversation, upserted on
  every turn.

  The store also implements `c:Legion.Store.save_run/2`, so the same row
  carries the conversation's identity: `agent_module` (in `inspect/1` form,
  e.g. `"MyApp.ResearchAgent"`), `parent_agent_id` linking a sub-agent to the
  conversation that spawned it, and `started_at` in milliseconds (last start
  wins). `snapshot` is null until the conversation's first turn completes;
  `parent_agent_id` is kept once set, so resuming from elsewhere does not
  reparent the conversation.

  `c:Legion.Store.save_status/2` is implemented as well: the row's `status`
  flips to `'running'` when a turn starts and back to `'idle'` when it
  completes (`save_run` resets it to `'idle'` on start), so consumers can
  identify conversations that were mid-turn when persistence last observed
  them.

  `c:Legion.Store.list_runs/1` and `c:Legion.Store.get_run/1` are implemented
  too, so persisted conversations can be read back into a view of past runs.

  The migration also installs a trigger that `pg_notify`s the table's channel
  (the table name) with the `agent_id` on every insert or update, so
  consumers can follow store changes live without polling.
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

    save_run_sql = """
    INSERT INTO #{table} (agent_id, agent_module, parent_agent_id, status, started_at, inserted_at, updated_at)
    VALUES ($1, $2, $3, 'idle', $4, now(), now())
    ON CONFLICT (agent_id) DO UPDATE
      SET agent_module = EXCLUDED.agent_module,
          parent_agent_id = COALESCE(#{table}.parent_agent_id, EXCLUDED.parent_agent_id),
          status = 'idle',
          started_at = EXCLUDED.started_at,
          updated_at = now()
    """

    save_status_sql = "UPDATE #{table} SET status = $2, updated_at = now() WHERE agent_id = $1"

    run_columns = "agent_id, agent_module, parent_agent_id, status, started_at"

    list_runs_sql =
      "SELECT #{run_columns} FROM #{table} ORDER BY started_at DESC NULLS LAST LIMIT $1"

    get_run_sql = "SELECT #{run_columns} FROM #{table} WHERE agent_id = $1"

    quote do
      @behaviour Legion.Store

      @impl Legion.Store
      # sobelow_skip ["Misc.BinToTerm"]
      def load(agent_id) when is_binary(agent_id) do
        case unquote(repo).query!(unquote(select_sql), [agent_id]) do
          %{rows: [[nil]]} -> :error
          %{rows: [[snapshot]]} -> {:ok, :erlang.binary_to_term(snapshot)}
          %{rows: []} -> :error
        end
      end

      @impl Legion.Store
      def save(agent_id, snapshot) when is_binary(agent_id) do
        unquote(repo).query!(unquote(upsert_sql), [agent_id, :erlang.term_to_binary(snapshot)])
        :ok
      end

      @impl Legion.Store
      def save_run(agent_id, metadata) when is_binary(agent_id) do
        unquote(repo).query!(unquote(save_run_sql), [
          agent_id,
          inspect(metadata.agent_module),
          metadata.parent_agent_id,
          metadata.started_at
        ])

        :ok
      end

      @impl Legion.Store
      def save_status(agent_id, status) when is_binary(agent_id) do
        unquote(repo).query!(unquote(save_status_sql), [agent_id, Atom.to_string(status)])
        :ok
      end

      @impl Legion.Store
      def list_runs(limit) do
        %{rows: rows} = unquote(repo).query!(unquote(list_runs_sql), [limit])
        Enum.map(rows, &Legion.Store.Postgres.decode_run_row/1)
      end

      @impl Legion.Store
      def get_run(agent_id) when is_binary(agent_id) do
        case unquote(repo).query!(unquote(get_run_sql), [agent_id]) do
          %{rows: [row]} -> Legion.Store.Postgres.decode_run_row(row)
          %{rows: []} -> nil
        end
      end

      @doc false
      def __repo__, do: unquote(repo)

      @doc false
      def __table__, do: unquote(table)
    end
  end

  @doc false
  def decode_run_row([agent_id, agent_module, parent_agent_id, status, started_at]) do
    %{
      agent_id: agent_id,
      agent_module: agent_module && Module.concat([agent_module]),
      parent_agent_id: parent_agent_id,
      status: decode_status(status),
      started_at: started_at
    }
  end

  defp decode_status("running"), do: :running
  defp decode_status("idle"), do: :idle
  defp decode_status(nil), do: nil
end
