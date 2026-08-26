defmodule Legion.RateLimiter.ExceededError do
  defexception [:agent_id, :identity, :policy, :usage, :violations]

  @impl Exception
  def message(%__MODULE__{identity: identity, violations: violations}) do
    "rate limit exceeded for #{inspect(identity)}: #{inspect(violations)}"
  end
end
