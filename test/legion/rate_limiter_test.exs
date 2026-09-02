defmodule Legion.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Legion.RateLimiter
  alias Legion.RateLimiter.Policy
  alias Legion.RateLimiter.Rule

  defmodule Limiter do
    @behaviour Legion.RateLimiter

    @impl Legion.RateLimiter
    def enforce!(_agent_id, _rules), do: :ok
  end

  defmodule OtherLimiter do
    @behaviour Legion.RateLimiter

    @impl Legion.RateLimiter
    def enforce!(_agent_id, _rules), do: :ok
  end

  @ip %{"ip" => "203.0.113.42"}
  @other_ip %{"ip" => "198.51.100.7"}
  @email %{"email" => "someone@example.com"}
  @policy %Policy{window_ms: 60_000, max_agents: 2}
  @narrow %Policy{window_ms: 1_000, max_agents: 1}
  @off %{limiter: nil, rules: []}

  setup do
    on_exit(fn -> Application.delete_env(:legion, :rate_limit) end)
    :ok
  end

  describe "resolve!/1" do
    test "resolves to no limit when nothing is configured" do
      assert RateLimiter.resolve!(nil) == @off
      assert RateLimiter.resolve!([]) == @off
    end

    test "combines the application limiter with the rules given at start" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter)

      assert RateLimiter.resolve!(rules: [rule(@ip, @policy)]) ==
               %{limiter: Limiter, rules: [rule(@ip, @policy)]}
    end

    test "a limiter given at start wins over the application limiter" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter)

      assert %{limiter: OtherLimiter} =
               RateLimiter.resolve!(limiter: OtherLimiter, rules: [rule(@ip, @policy)])
    end

    test "fills a rule's missing policy from the application policy" do
      Application.put_env(:legion, :rate_limit,
        limiter: Limiter,
        default_policy: @policy,
        rules: [%Rule{identity: %{}}]
      )

      assert RateLimiter.resolve!(nil) == %{limiter: Limiter, rules: [rule(%{}, @policy)]}

      assert RateLimiter.resolve!(rules: [%Rule{identity: @ip}, rule(@email, @narrow)]) ==
               %{limiter: Limiter, rules: [rule(@ip, @policy), rule(@email, @narrow)]}
    end

    test "raises when a rule has no policy and no application policy is set" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter)

      assert_raise ArgumentError, ~r/Legion\.RateLimiter\.Policy/, fn ->
        RateLimiter.resolve!(rules: [%Rule{identity: @ip}])
      end
    end

    test "resolves to no limit with rules but no limiter, or a limiter but no rules" do
      assert RateLimiter.resolve!(rules: [rule(@ip, @policy)]) == @off

      Application.put_env(:legion, :rate_limit, limiter: Limiter)

      assert RateLimiter.resolve!(nil) == @off
      assert RateLimiter.resolve!(rules: []) == @off
    end

    test "applies the application rules to an agent started without any" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter, rules: [rule(%{}, @policy)])

      assert RateLimiter.resolve!(nil) == %{limiter: Limiter, rules: [rule(%{}, @policy)]}
    end

    test "inherits the parent's rate limit over the application config" do
      Application.put_env(:legion, :rate_limit,
        limiter: OtherLimiter,
        rules: [rule(%{}, @policy)]
      )

      Vault.unsafe_put(:rate_limit, %{limiter: Limiter, rules: [rule(@ip, @policy)]})

      assert RateLimiter.resolve!(nil) == %{limiter: Limiter, rules: [rule(@ip, @policy)]}
    end

    test "a sub-agent of a parent that opted out stays unlimited" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter, rules: [rule(%{}, @policy)])
      Vault.unsafe_put(:rate_limit, @off)

      assert RateLimiter.resolve!(nil) == @off
    end

    test "a rate limit given at start replaces the parent's as a whole" do
      Vault.unsafe_put(:rate_limit, %{limiter: Limiter, rules: [rule(@ip, @policy)]})

      assert RateLimiter.resolve!(limiter: OtherLimiter, rules: [rule(@email, @narrow)]) ==
               %{limiter: OtherLimiter, rules: [rule(@email, @narrow)]}

      assert RateLimiter.resolve!(limiter: OtherLimiter) == @off
    end

    test "validates rules even when no limiter is configured" do
      assert_raise ArgumentError, ~r/:identity keys/, fn ->
        RateLimiter.resolve!(rules: [rule(%{ip: "203.0.113.42"}, @policy)])
      end
    end

    test "rejects rules that disagree on an identity value" do
      assert_raise ArgumentError, ~r/disagree on "ip"/, fn ->
        RateLimiter.resolve!(rules: [rule(@ip, @policy), rule(@other_ip, @narrow)])
      end
    end

    test "accepts rules that share an identity under different policies" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter)

      assert %{rules: [_, _]} =
               RateLimiter.resolve!(rules: [rule(@ip, @policy), rule(@ip, @narrow)])
    end

    test "rejects malformed options and config" do
      assert_raise ArgumentError, ~r/expected a keyword list/, fn ->
        RateLimiter.resolve!([rule(@ip, @policy)])
      end

      assert_raise ArgumentError, ~r/unknown keys \[:policy\]/, fn ->
        RateLimiter.resolve!(policy: @policy)
      end

      assert_raise ArgumentError, ~r/expected :rules to be a list/, fn ->
        RateLimiter.resolve!(rules: rule(@ip, @policy))
      end

      assert_raise ArgumentError, ~r/expected a Legion\.RateLimiter\.Rule/, fn ->
        RateLimiter.resolve!(rules: [%{identity: @ip, policy: @policy}])
      end

      Application.put_env(:legion, :rate_limit, limiter: Limiter, policy: @policy)

      assert_raise ArgumentError, ~r/unknown keys \[:policy\]/, fn ->
        RateLimiter.resolve!(nil)
      end
    end
  end

  describe "Rule.validate!/1" do
    test "accepts a complete rule" do
      assert :ok = Rule.validate!(rule(@ip, @policy))
    end

    test "accepts an empty identity" do
      assert :ok = Rule.validate!(rule(%{}, @policy))
    end

    test "rejects a non-struct" do
      assert_raise ArgumentError, ~r/expected a Legion\.RateLimiter\.Rule struct/, fn ->
        Rule.validate!(%{identity: @ip, policy: @policy})
      end
    end

    test "rejects an identity that is not a map" do
      assert_raise ArgumentError, ~r/expected :identity to be a map/, fn ->
        Rule.validate!(rule("203.0.113.42", @policy))
      end
    end

    test "rejects identity keys that are not strings" do
      assert_raise ArgumentError, ~r/expected :identity keys to be strings, got: \[:ip\]/, fn ->
        Rule.validate!(rule(%{ip: "203.0.113.42"}, @policy))
      end
    end

    test "rejects a missing policy" do
      assert_raise ArgumentError, ~r/Legion\.RateLimiter\.Policy/, fn ->
        Rule.validate!(%Rule{identity: @ip})
      end
    end

    test "rejects an invalid policy" do
      assert_raise ArgumentError, ~r/:max_agents/, fn ->
        Rule.validate!(rule(@ip, %Policy{window_ms: 1_000, max_agents: -1}))
      end
    end
  end

  defp rule(identity, policy), do: %Rule{identity: identity, policy: policy}
end
