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

for sql <- Legion.Store.Postgres.Migration.down_sql(1, "legion_agents") do
  Postgrex.query!(:legion_store_test, sql, [])
end

for sql <- Legion.Store.Postgres.Migration.up_sql(1, "legion_agents") do
  Postgrex.query!(:legion_store_test, sql, [])
end

ExUnit.start(exclude: [:integration])
