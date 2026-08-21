defmodule Legion.RateLimiter.PolicyTest do
  use ExUnit.Case, async: true

  alias Legion.RateLimiter.Policy

  describe "validate!/1" do
    test "accepts a policy with both limits set" do
      assert :ok = Policy.validate!(%Policy{interval_ms: 1_000, max_agents: 1, max_tokens: 10})
    end

    test "accepts an unrestricted policy" do
      assert :ok = Policy.validate!(%Policy{interval_ms: 1_000})
    end

    test "accepts zero limits" do
      assert :ok = Policy.validate!(%Policy{interval_ms: 1_000, max_agents: 0, max_tokens: 0})
    end

    test "rejects a non-positive interval" do
      assert_raise ArgumentError, ~r/:interval_ms/, fn ->
        Policy.validate!(%Policy{interval_ms: 0})
      end
    end

    test "rejects a negative limit" do
      assert_raise ArgumentError, ~r/:max_agents/, fn ->
        Policy.validate!(%Policy{interval_ms: 1_000, max_agents: -1})
      end
    end

    test "rejects a non-integer limit" do
      assert_raise ArgumentError, ~r/:max_tokens/, fn ->
        Policy.validate!(%Policy{interval_ms: 1_000, max_tokens: "10"})
      end
    end

    test "rejects anything that is not a policy" do
      assert_raise ArgumentError, ~r/Legion.RateLimiter.Policy/, fn ->
        Policy.validate!(%{interval_ms: 1_000})
      end
    end
  end
end
