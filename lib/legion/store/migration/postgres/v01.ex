defmodule Legion.Store.Migration.Postgres.V01 do
  @moduledoc false

  use Ecto.Migration

  def up(opts) do
    table = Keyword.fetch!(opts, :table)

    create_if_not_exists table(table, primary_key: false) do
      add :agent_id, :text, primary_key: true
      add :agent_module, :text
      add :parent_agent_id, :text
      add :status, :text, null: false, default: "idle"
      add :started_at, :naive_datetime_usec
      add :conversation_state, :binary
      add :usage, {:array, :map}, null: false, default: []
      add :limit_meta, :map

      add :inserted_at, :naive_datetime_usec,
        null: false,
        default: fragment("now()")

      add :updated_at, :naive_datetime_usec,
        null: false,
        default: fragment("now()")
    end

    execute """
    CREATE INDEX IF NOT EXISTS #{table}_limit_meta_gin_idx
    ON #{table}
    USING GIN (limit_meta jsonb_path_ops);
    """

    execute """
    CREATE OR REPLACE FUNCTION #{table}_notify() RETURNS trigger AS $$
    BEGIN
      PERFORM pg_notify('#{table}', NEW.agent_id);
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute "DROP TRIGGER IF EXISTS #{table}_notify ON #{table}"

    execute """
    CREATE TRIGGER #{table}_notify AFTER INSERT OR UPDATE ON #{table}
    FOR EACH ROW EXECUTE FUNCTION #{table}_notify()
    """
  end

  def down(opts) do
    table = Keyword.fetch!(opts, :table)

    execute "DROP INDEX IF EXISTS #{table}_limit_meta_gin_idx"

    drop_if_exists table(table)
    execute "DROP FUNCTION IF EXISTS #{table}_notify()"
  end
end
