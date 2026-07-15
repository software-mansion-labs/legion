defmodule Legion.Store.Postgres.Migration do
  @moduledoc """
  Migration helpers for `Legion.Store.Postgres`.

  ## Usage

      defmodule MyApp.Repo.Migrations.AddLegionAgents do
        use Ecto.Migration

        def up, do: Legion.Store.Postgres.Migration.up()
        def down, do: Legion.Store.Postgres.Migration.down()
      end

  Migrations are versioned and idempotent - `up/1` only runs the versions the
  database hasn't seen yet, so when a new Legion release ships schema changes
  you generate another migration with the same two calls (optionally pinning
  `version:`):

      defmodule MyApp.Repo.Migrations.UpgradeLegionAgentsToV2 do
        use Ecto.Migration

        def up, do: Legion.Store.Postgres.Migration.up(version: 2)
        def down, do: Legion.Store.Postgres.Migration.down(version: 2)
      end

  ## Options

    - `:table` - the table name, defaults to `"legion_agents"`. Must match
      the `:table` given to `use Legion.Store.Postgres`.
    - `:version` - the target version. `up/1` defaults to the latest version,
      `down/1` to rolling everything back.
  """

  # Legion does not depend on Ecto - these run inside the host app's
  # migrations, where Ecto.Migration is available.
  @compile {:no_warn_undefined, Ecto.Migration}

  @default_table "legion_agents"
  @initial_version 1
  @current_version 1

  @doc "Migrates the agents table up to `:version`, defaulting to the latest."
  def up(opts \\ []) do
    table = table(opts)
    version = Keyword.get(opts, :version, @current_version)
    migrated = migrated_version(opts)

    if migrated < version do
      for step <- (migrated + 1)..version, sql <- List.wrap(up_sql(step, table)) do
        Ecto.Migration.execute(sql)
      end

      record_version(table, version)
    end

    :ok
  end

  @doc "Rolls the agents table back down to and including `:version`."
  def down(opts \\ []) do
    table = table(opts)
    version = Keyword.get(opts, :version, @initial_version)
    migrated = migrated_version(opts)

    if migrated >= version do
      for step <- migrated..version//-1, sql <- List.wrap(down_sql(step, table)) do
        Ecto.Migration.execute(sql)
      end

      record_version(table, version - 1)
    end

    :ok
  end

  @doc "Returns the version the database is migrated to, `0` when the table is absent."
  def migrated_version(opts \\ []) do
    # The version lives in the table's comment, read directly so it reflects
    # the database before this migration's queued commands run.
    query = """
    SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
    FROM pg_class
    WHERE pg_class.relname = '#{table(opts)}'
    """

    case Ecto.Migration.repo().query(query, [], log: false) do
      {:ok, %{rows: [[version]]}} when is_binary(version) -> String.to_integer(version)
      _ -> 0
    end
  end

  defp record_version(_table, 0), do: :ok

  defp record_version(table, version) do
    Ecto.Migration.execute("COMMENT ON TABLE #{table} IS '#{version}'")
  end

  # The trigger notifies the table's channel with the agent_id on every
  # write, so consumers (e.g. LegionWeb.Source.Listener) can refresh from the
  # database instead of capturing telemetry. Postgres has no CREATE TRIGGER
  # IF NOT EXISTS, so the trigger is dropped first to keep the step idempotent.
  @doc false
  def up_sql(1, table) do
    [
      """
      CREATE TABLE IF NOT EXISTS #{table} (
        agent_id text PRIMARY KEY,
        agent_module text,
        parent_agent_id text,
        pid bytea,
        status text,
        started_at bigint,
        snapshot bytea,
        inserted_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now()
      )
      """,
      """
      CREATE OR REPLACE FUNCTION #{table}_notify() RETURNS trigger AS $$
      BEGIN
        PERFORM pg_notify('#{table}', NEW.agent_id);
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP TRIGGER IF EXISTS #{table}_notify ON #{table}",
      """
      CREATE TRIGGER #{table}_notify AFTER INSERT OR UPDATE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION #{table}_notify()
      """
    ]
  end

  @doc false
  def down_sql(1, table) do
    [
      "DROP TABLE IF EXISTS #{table}",
      "DROP FUNCTION IF EXISTS #{table}_notify()"
    ]
  end

  defp table(opts), do: Keyword.get(opts, :table, @default_table)
end
