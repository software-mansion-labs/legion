defmodule Legion.Store.Migration.Postgres do
  @moduledoc """
  Runs versioned PostgreSQL migrations for `Legion.Store.Postgres`.

  ## Usage

      defmodule MyApp.Repo.Migrations.AddLegionAgents do
        use Ecto.Migration

        def up, do: Legion.Store.Migration.Postgres.up()
        def down, do: Legion.Store.Migration.Postgres.down()
      end

  Migrations are versioned and idempotent. `up/1` applies only versions that
  haven't already run and records the resulting version in the table comment.

  When a new Legion release adds a schema version, generate another migration
  using the same calls. You can pin that migration to a specific version:

      defmodule MyApp.Repo.Migrations.UpgradeLegionAgentsToV2 do
        use Ecto.Migration

        def up, do: Legion.Store.Migration.Postgres.up(version: 2)
        def down, do: Legion.Store.Migration.Postgres.down(version: 2)
      end

  Rolling back the example above removes version 2 and leaves version 1 applied.

  ## Options

    * `:table` - the table name, defaults to `"legion_agents"`. It must match
      the `:table` given to `use Legion.Store.Postgres`.
    * `:version` - the target version. `up/1` defaults to the latest version;
      `down/1` defaults to rolling back all versions.

  ## Migrating Without Ecto

  If your application uses something other than Ecto for migrations, be it an external system or
  another ORM, it may be helpful to create plain SQL migrations for Legion's database schema changes.

  The simplest mechanism for obtaining the SQL changes is to create the migration locally and run
  `mix ecto.migrate --log-migrations-sql`. That will log all of the generated SQL, which you can
  then paste into your migration system of choice.
  """

  use Ecto.Migration

  @default_table "legion_agents"
  @initial_version 1
  @current_version 1

  def up(opts \\ []) do
    opts = Keyword.put_new(opts, :table, @default_table)
    initial = migrated_version(opts)
    migrated = Keyword.get(opts, :version, @current_version)

    if initial < migrated do
      change((initial + 1)..migrated, :up, opts)
    end

    :ok
  end

  def down(opts \\ []) do
    opts = Keyword.put_new(opts, :table, @default_table)
    initial = max(migrated_version(opts), @initial_version)
    migrated = Keyword.get(opts, :version, @initial_version)

    if initial >= migrated do
      change(initial..migrated//-1, :down, opts)
    end

    :ok
  end

  def migrated_version(opts \\ []) do
    opts = Keyword.put_new(opts, :table, @default_table)
    table = Keyword.fetch!(opts, :table)

    query = """
    SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
    FROM pg_class
    WHERE pg_class.relname = '#{table}'
    """

    case Ecto.Migration.repo().query(query, [], log: false) do
      {:ok, %{rows: [[version]]}} when is_binary(version) -> String.to_integer(version)
      _ -> 0
    end
  end

  defp change(range, direction, opts) do
    for index <- range do
      pad_idx = String.pad_leading(to_string(index), 2, "0")

      [__MODULE__, "V#{pad_idx}"]
      |> Module.concat()
      |> apply(direction, [opts])
    end

    case direction do
      :up -> record_version(opts, Enum.max(range))
      :down -> record_version(opts, Enum.min(range) - 1)
    end
  end

  defp record_version(_opts, 0), do: :ok

  defp record_version(opts, version) do
    table = Keyword.get(opts, :table, @default_table)
    Ecto.Migration.execute("COMMENT ON TABLE #{table} IS '#{version}'")
  end
end
