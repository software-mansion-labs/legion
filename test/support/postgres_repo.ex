defmodule Legion.Test.Support.PostgresRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :legion,
    adapter: Ecto.Adapters.Postgres
end
