defmodule Legion.RateLimiter.Migration.Postgres do
  @moduledoc """
  Adds Postgres rate-limiting metadata to a `Legion.Store.Postgres` table.

  Run this migration only after `Legion.Store.Migration.Postgres` has created
  the agents table. It adds the metadata column and indexes used by
  `Legion.RateLimiter.Postgres`:

      defmodule MyApp.Repo.Migrations.AddLegionRateLimiter do
        use Ecto.Migration

        def up, do: Legion.RateLimiter.Migration.Postgres.up()
        def down, do: Legion.RateLimiter.Migration.Postgres.down()
      end

  Both directions are idempotent. Roll this migration back before removing the
  Store table.

  ## Options

    * `:table` - Store table to extend, defaulting to `"legion_agents"`. It
      must match the `:table` configured for `Legion.Store.Postgres` and
      `Legion.RateLimiter.Postgres`.
  """

  use Ecto.Migration

  @default_table "legion_agents"

  def up(opts \\ []) do
    table_name = Keyword.get(opts, :table, @default_table)

    alter table(table_name) do
      add_if_not_exists :limit_meta, :map
    end

    execute """
    CREATE INDEX IF NOT EXISTS #{table_name}_limit_meta_gin_idx
    ON #{table_name}
    USING GIN (limit_meta jsonb_path_ops);
    """

    create_if_not_exists index(table_name, [:started_at])
  end

  def down(opts \\ []) do
    table_name = Keyword.get(opts, :table, @default_table)

    execute "DROP INDEX IF EXISTS #{table_name}_limit_meta_gin_idx"

    drop_if_exists index(table_name, [:started_at])

    alter table(table_name) do
      remove_if_exists :limit_meta
    end
  end
end
