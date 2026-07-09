Mimic.copy(ReqLLM)

Legion.Telemetry.attach_default_logger()

# Shared connection and schema for the Legion.Store.Postgres database tests.
{:ok, _} =
  Postgrex.start_link(
    name: :legion_store_test,
    hostname: System.get_env("POSTGRES_HOST", "localhost"),
    port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
    username: System.get_env("POSTGRES_USER", "postgres"),
    password: System.get_env("POSTGRES_PASSWORD", "postgres"),
    database: System.get_env("POSTGRES_DB", "postgres")
  )

Postgrex.query!(
  :legion_store_test,
  """
  CREATE TABLE IF NOT EXISTS legion_agents (
    agent_id text PRIMARY KEY,
    snapshot bytea NOT NULL,
    inserted_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
  )
  """,
  []
)

ExUnit.start(exclude: [:integration])
