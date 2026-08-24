defmodule LegionPopcornClient.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [LegionPopcornClient.Evaluator]
    Supervisor.start_link(children, strategy: :one_for_one, name: LegionPopcornClient.Supervisor)
  end
end
