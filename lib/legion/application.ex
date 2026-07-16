defmodule Legion.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Legion.AgentRegistry}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Legion.Supervisor)
  end
end
