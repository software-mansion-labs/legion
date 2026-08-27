defmodule Legion.RateLimiter.Rule do
  @moduledoc """
  One rate-limit rule: the group it applies to and the limits it enforces.

      %Legion.RateLimiter.Rule{
        identity: %{"ip" => "203.0.113.42"},
        policy: %Legion.RateLimiter.Policy{window_ms: :timer.minutes(1), max_agents: 10}
      }

  ## Fields

    * `:identity` (required) - string-keyed map naming the group. Agents with
      matching identities consume the same rolling-window limits; how "matching"
      is decided belongs to the adapter (`Legion.RateLimiter.Postgres` uses JSON
      containment, so a broader identity also covers agents recorded with extra
      fields). `%{}` matches every agent.
    * `:policy` - the `Legion.RateLimiter.Policy` to enforce. May be left `nil`
      in `Legion.start_link/2` options, where it is filled from
      `config :legion, :rate_limit, default_policy: ...`; adapters always receive a
      complete rule.

  See `Legion.RateLimiter` for how rules are configured and combined.
  """

  alias Legion.RateLimiter

  @enforce_keys [:identity]
  defstruct [:identity, :policy]

  @type t :: %__MODULE__{
          identity: RateLimiter.limit_identity(),
          policy: RateLimiter.Policy.t() | nil
        }

  @doc """
  Returns `:ok` when `rule` is complete and usable.

  Raises `ArgumentError` naming the offending field: a non-map identity,
  identity keys that are not strings, or a missing or invalid policy (see
  `Legion.RateLimiter.Policy.validate!/1`). Legion calls this when an agent
  starts, so a bad rule fails at the agent that configured it.
  """
  def validate!(%__MODULE__{} = rule) do
    validate_identity!(rule.identity)
    RateLimiter.Policy.validate!(rule.policy)

    :ok
  end

  def validate!(other) do
    raise ArgumentError,
          "expected a #{inspect(__MODULE__)} struct, got: #{inspect(other)}"
  end

  defp validate_identity!(identity) when is_map(identity) do
    case Enum.reject(Map.keys(identity), &is_binary/1) do
      [] ->
        :ok

      keys ->
        raise ArgumentError,
              "expected :identity keys to be strings, got: #{inspect(keys)}"
    end
  end

  defp validate_identity!(other) do
    raise ArgumentError, "expected :identity to be a map, got: #{inspect(other)}"
  end
end
