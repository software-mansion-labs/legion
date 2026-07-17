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

    table_columns =
      "agent_id, agent_module, parent_agent_id, status, started_at, conversation_state"

    select_sql = "SELECT #{table_columns} FROM #{table} WHERE agent_id = $1"

    list_sql =
      "SELECT #{table_columns} FROM #{table} ORDER BY updated_at DESC NULLS LAST LIMIT $1"

    save_state_sql = """
    INSERT INTO #{table} (agent_id, conversation_state, inserted_at, updated_at)
    VALUES ($1, $2, now(), now())
    ON CONFLICT (agent_id) DO UPDATE SET conversation_state = EXCLUDED.conversation_state, updated_at = now()
    """

    save_metadata_sql = """
    INSERT INTO #{table} (agent_id, agent_module, parent_agent_id, started_at, inserted_at, updated_at)
    VALUES ($1, $2, $3, $4, now(), now())
    ON CONFLICT (agent_id) DO UPDATE
      SET agent_module = EXCLUDED.agent_module,
          parent_agent_id = COALESCE(#{table}.parent_agent_id, EXCLUDED.parent_agent_id),
          started_at = EXCLUDED.started_at,
          updated_at = now()
    """

    save_status_sql = """
    INSERT INTO #{table} (agent_id, status, inserted_at, updated_at)
    VALUES ($1, $2, now(), now())
    ON CONFLICT (agent_id) DO UPDATE
      SET status = EXCLUDED.status, updated_at = now()
    """

    quote do
      use Legion.Store

      alias Legion.Store.Postgres

      @impl Legion.Store
      def get(agent_id) when is_binary(agent_id) do
        case unquote(repo).query!(unquote(select_sql), [agent_id]) do
          %{rows: []} -> :error
          %{rows: [row]} -> {:ok, Postgres.decode_conversation(row)}
        end
      end

      @impl Legion.Store
      def list(limit) when is_integer(limit) and limit > 0 do
        %{rows: rows} = unquote(repo).query!(unquote(list_sql), [limit])
        Enum.map(rows, &Postgres.decode_conversation/1)
      end

      @impl Legion.Store
      def save(agent_id, %Legion.Store.Conversation.State{} = state) when is_binary(agent_id) do
        unquote(repo).query!(unquote(save_state_sql), [agent_id, :erlang.term_to_binary(state)])
        :ok
      end

      @impl Legion.Store
      def save(agent_id, %Legion.Store.Conversation.Metadata{} = metadata)
          when is_binary(agent_id) do
        unquote(repo).query!(
          unquote(save_metadata_sql),
          [agent_id] ++ Postgres.encode_metadata(metadata)
        )

        :ok
      end

      @impl Legion.Store
      def save(agent_id, {:status, status})
          when is_binary(agent_id) and status in [:running, :idle] do
        unquote(repo).query!(unquote(save_status_sql), [agent_id, Atom.to_string(status)])
        :ok
      end

      def save(_agent_id, _payload), do: :error

      @doc false
      def __repo__, do: unquote(repo)

      @doc false
      def __table__, do: unquote(table)
    end
  end

  @doc false
  def decode_conversation([
        agent_id,
        agent_module,
        parent_agent_id,
        status,
        started_at,
        conversation_state | _
      ]) do
    %Legion.Store.Conversation{
      agent_id: agent_id,
      metadata: decode_metadata(agent_module, parent_agent_id, started_at),
      status: decode_status(status),
      state: decode_state(conversation_state)
    }
  end

  @doc false
  def encode_metadata(%Legion.Store.Conversation.Metadata{} = metadata) do
    [
      metadata.agent_module && inspect(metadata.agent_module),
      metadata.parent_agent_id,
      metadata.started_at
    ]
  end

  defp decode_metadata(nil, nil, nil), do: nil

  defp decode_metadata(agent_module, parent_agent_id, started_at) do
    %Legion.Store.Conversation.Metadata{
      agent_module: agent_module && Module.concat([agent_module]),
      parent_agent_id: parent_agent_id,
      started_at: started_at
    }
  end

  defp decode_state(nil), do: nil

  # sobelow_skip ["Misc.BinToTerm"]
  defp decode_state(binary) when is_binary(binary) do
    state = :erlang.binary_to_term(binary)

    %Legion.Store.Conversation.State{
      messages: Map.get(state, :messages, []),
      bindings: Map.get(state, :bindings, [])
    }
  end

  defp decode_status("running"), do: :running
  defp decode_status("idle"), do: :idle
  defp decode_status(nil), do: nil
end
