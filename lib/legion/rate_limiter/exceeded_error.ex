defmodule Legion.RateLimiter.ExceededError do
  defexception [:agent_id, :key, :policy, :usage, :violations]

  @impl Exception
  def message(%__MODULE__{key: key, violations: violations}) do
    "rate limit exceeded for #{inspect(key)}: #{inspect(violations)}"
  end
end
