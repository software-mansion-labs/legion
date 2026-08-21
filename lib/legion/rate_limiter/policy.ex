defmodule Legion.RateLimiter.Policy do
  @moduledoc """
  Defines the limits enforced by a `Legion.RateLimiter`.

  Every policy has a rolling `:interval_ms`. Within that interval, it can
  limit newly admitted agents matching a rate-limit key, recorded token usage
  for those agents, or both:

      %Legion.RateLimiter.Policy{
        interval_ms: :timer.minutes(1),
        max_agents: 10,
        max_tokens: 100_000
      }

  ## Limits

    * `:interval_ms` (required) - positive rolling-window duration in
      milliseconds.
    * `:max_agents` - maximum number of matching agent IDs admitted during the
      interval, including sub-agents spawned by an admitted agent. `0` admits
      no agents; `nil` disables this limit.
    * `:max_tokens` - maximum recorded token total for matching agents during
      the interval. Limits are checked when a turn starts and never interrupt
      a running turn, so `0` refuses every turn after the first one that
      records usage; `nil` disables this limit.

  A policy with both optional limits set to `nil` is unrestricted. See
  `Legion.RateLimiter` for the adapter interface and
  `Legion.RateLimiter.Postgres` for the bundled implementation.
  """

  @enforce_keys [:interval_ms]
  defstruct [:interval_ms, :max_agents, :max_tokens]

  @type t :: %__MODULE__{
          interval_ms: pos_integer(),
          max_agents: non_neg_integer() | nil,
          max_tokens: non_neg_integer() | nil
        }

  @doc """
  Returns `:ok` when `policy` is a usable policy.

  Raises `ArgumentError` naming the offending field otherwise. Legion calls
  this when an agent starts, so a misconfigured policy fails at the agent that
  configured it rather than at the first limit evaluation.
  """
  def validate!(%__MODULE__{} = policy) do
    validate_interval!(policy.interval_ms)
    validate_limit!(:max_agents, policy.max_agents)
    validate_limit!(:max_tokens, policy.max_tokens)

    :ok
  end

  def validate!(other) do
    raise ArgumentError,
          "expected a #{inspect(__MODULE__)} struct, got: #{inspect(other)}"
  end

  defp validate_interval!(interval_ms) when is_integer(interval_ms) and interval_ms > 0, do: :ok

  defp validate_interval!(other) do
    raise ArgumentError,
          "expected :interval_ms to be a positive integer, got: #{inspect(other)}"
  end

  defp validate_limit!(_name, nil), do: :ok
  defp validate_limit!(_name, limit) when is_integer(limit) and limit >= 0, do: :ok

  defp validate_limit!(name, other) do
    raise ArgumentError,
          "expected #{inspect(name)} to be a non-negative integer or nil, got: #{inspect(other)}"
  end
end
