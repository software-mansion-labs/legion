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

  alias Legion.Store.Payload

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    table = Keyword.get(opts, :table, "legion_agents")

    quote do
      @behaviour Legion.Store

      import Ecto.Query, only: [from: 2]

      alias Legion.Store.Payload
      alias Legion.Store.Postgres

      defmodule Record do
        use Ecto.Schema

        @primary_key {:agent_id, :string, autogenerate: false}

        schema unquote(table) do
          field(:agent_module, :string)
          field(:parent_agent_id, :string)
          field(:status, :string)
          field(:started_at, :integer)
          field(:conversation_state, :binary)
          field(:inserted_at, :utc_datetime_usec)
          field(:updated_at, :utc_datetime_usec)
        end
      end

      @impl Legion.Store
      def get(agent_id) when is_binary(agent_id) do
        case unquote(repo).get(Record, agent_id) do
          nil -> :error
          record -> {:ok, Postgres.decode_record(record)}
        end
      end

      @impl Legion.Store
      def list(limit) when is_integer(limit) and limit > 0 do
        from(record in Record, order_by: [desc: record.updated_at], limit: ^limit)
        |> unquote(repo).all()
        |> Enum.map(&Postgres.decode_record/1)
      end

      def save(map) when is_map(map) and not is_struct(map), do: :error

      @impl Legion.Store
      def save(%Payload{agent_id: nil}), do: :error

      @impl Legion.Store
      def save(%Payload{} = payload) do
        attrs =
          payload
          |> Postgres.encode_data()
          |> Map.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.put(:updated_at, DateTime.utc_now())

        update_columns = attrs |> Map.delete(:agent_id) |> Map.keys()

        case unquote(repo).insert_all(
               Record,
               [attrs],
               conflict_target: :agent_id,
               on_conflict: {:replace, update_columns}
             ) do
          {1, _} -> :ok
          _ -> :error
        end
      end

      @doc false
      def __repo__, do: unquote(repo)

      @doc false
      def __table__, do: unquote(table)
    end
  end

  def encode_data(%Payload{} = payload) do
    payload
    |> Map.from_struct()
    |> Map.update(:conversation_state, nil, fn state ->
      if is_nil(state), do: nil, else: :erlang.term_to_binary(state)
    end)
    |> Map.update(:agent_module, nil, fn module ->
      if is_nil(module), do: nil, else: inspect(module)
    end)
    |> Map.update(:status, nil, fn status ->
      if is_nil(status), do: nil, else: Atom.to_string(status)
    end)
  end

  @doc false
  def decode_record(record) do
    %Payload{
      agent_id: record.agent_id,
      agent_module: record.agent_module && Module.concat([record.agent_module]),
      parent_agent_id: record.parent_agent_id,
      status: decode_status(record.status),
      started_at: record.started_at,
      conversation_state: decode_conversation_state(record.conversation_state)
    }
  end

  defp decode_conversation_state(nil), do: nil

  # sobelow_skip ["Misc.BinToTerm"]
  defp decode_conversation_state(binary) when is_binary(binary) do
    state = :erlang.binary_to_term(binary)

    %{
      messages: Map.get(state, :messages, []),
      bindings: Map.get(state, :bindings, [])
    }
  end

  defp decode_status("running"), do: :running
  defp decode_status("idle"), do: :idle
  defp decode_status(nil), do: nil
end
