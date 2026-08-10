defmodule Legion.Application do
  @moduledoc """
  The OTP application for Legion.
  """

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: Legion.Supervisor)
  end

  @doc false
  def children do
    [
      {Legion.Recovery, Application.fetch_env(:legion, :recovery)}
    ]
  end
end
