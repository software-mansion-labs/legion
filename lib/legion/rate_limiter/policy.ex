defmodule Legion.RateLimiter.Policy do
  @moduledoc """
  Defines the limits enforced by a `Legion.RateLimiter`.

  Every policy has a rolling `:interval_ms`. Within that interval, it can
  limit newly admitted agents, recorded token usage, or both:

      %Legion.RateLimiter.Policy{
        interval_ms: :timer.minutes(1),
        max_agents: 10,
        max_tokens: 100_000
      }

  ## Limits

    * `:interval_ms` (required) - positive rolling-window duration in
      milliseconds.
    * `:max_agents` - maximum number of matching agents admitted during the
      interval. `0` admits no agents; `nil` disables this limit.
    * `:max_tokens` - maximum recorded token total for matching agents during
      the interval. `0` allows no token use; `nil` disables this limit.

  A policy with both optional limits set to `nil` is unrestricted. See
  `Legion.RateLimiter` for the adapter interface and
  `Legion.RateLimiter.Postgres` for the bundled implementation.
  """

  @enforce_keys [:interval_ms]
  defstruct [:interval_ms, :max_agents, :max_tokens]

  @type t :: %__MODULE__{
          interval_ms: pos_integer(),
          max_agents: pos_integer() | nil,
          max_tokens: non_neg_integer() | nil
        }
end
