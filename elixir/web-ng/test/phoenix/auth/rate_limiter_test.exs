defmodule ServiceRadarWebNGWeb.Auth.RateLimiterTest do
  @moduledoc """
  Tests for authentication rate limiter.

  These tests don't require database access but need the application started
  (for ETS tables). The test_helper.exs currently requires database connection,
  so these tests run as part of the standard test suite.

  Run with: mix test test/phoenix/auth/rate_limiter_test.exs
  """

  use ExUnit.Case, async: false

  alias ServiceRadarWebNGWeb.Auth.RateLimiter

  # RateLimiter uses ETS which is started by the application

  setup do
    # Generate unique action and IP for each test to avoid collisions
    action = "test_action_#{System.unique_integer([:positive])}"
    ip = "192.168.1.#{:rand.uniform(255)}"

    # Ensure clean state
    RateLimiter.clear_rate_limit(action, ip)

    {:ok, action: action, ip: ip}
  end

  describe "check_rate_limit/3" do
    test "returns :ok when under limit", %{action: action, ip: ip} do
      assert :ok = RateLimiter.check_rate_limit(action, ip)
    end

    test "returns :ok after recording fewer attempts than limit", %{action: action, ip: ip} do
      # Default limit is 5
      Enum.each(1..4, fn _ ->
        assert :ok = RateLimiter.check_rate_limit(action, ip)
        RateLimiter.record_attempt(action, ip)
      end)

      # Still under limit
      assert :ok = RateLimiter.check_rate_limit(action, ip)
    end

    test "returns {:error, retry_after} when limit exceeded", %{action: action, ip: ip} do
      # Record 5 attempts (default limit)
      Enum.each(1..5, fn _ ->
        RateLimiter.record_attempt(action, ip)
      end)

      # Should be rate limited now
      assert {:error, retry_after} = RateLimiter.check_rate_limit(action, ip)
      assert is_integer(retry_after)
      assert retry_after > 0
      # default window is 60 seconds
      assert retry_after <= 60
    end

    test "respects custom limit option", %{action: action, ip: ip} do
      # Record 2 attempts
      RateLimiter.record_attempt(action, ip)
      RateLimiter.record_attempt(action, ip)

      # With limit of 2, should be rate limited
      assert {:error, _} = RateLimiter.check_rate_limit(action, ip, limit: 2)

      # With limit of 5, should be ok
      assert :ok = RateLimiter.check_rate_limit(action, ip, limit: 5)
    end

    test "respects custom window option", %{action: action, ip: ip} do
      # Record 5 attempts
      Enum.each(1..5, fn _ ->
        RateLimiter.record_attempt(action, ip)
      end)

      # With 60 second window, should be rate limited
      assert {:error, _} = RateLimiter.check_rate_limit(action, ip, window_seconds: 60)
    end

    test "different actions are independent", %{ip: ip} do
      action1 = "action1_#{System.unique_integer([:positive])}"
      action2 = "action2_#{System.unique_integer([:positive])}"

      # Fill up action1
      Enum.each(1..5, fn _ ->
        RateLimiter.record_attempt(action1, ip)
      end)

      # action1 should be limited
      assert {:error, _} = RateLimiter.check_rate_limit(action1, ip)

      # action2 should not be affected
      assert :ok = RateLimiter.check_rate_limit(action2, ip)
    end

    test "different IPs are independent", %{action: action} do
      ip1 = "10.0.0.1"
      ip2 = "10.0.0.2"

      # Fill up ip1
      Enum.each(1..5, fn _ ->
        RateLimiter.record_attempt(action, ip1)
      end)

      # ip1 should be limited
      assert {:error, _} = RateLimiter.check_rate_limit(action, ip1)

      # ip2 should not be affected
      assert :ok = RateLimiter.check_rate_limit(action, ip2)
    end
  end

  describe "record_attempt/2" do
    test "records an attempt", %{action: action, ip: ip} do
      assert :ok = RateLimiter.record_attempt(action, ip)
    end

    test "multiple attempts are recorded", %{action: action, ip: ip} do
      Enum.each(1..3, fn _ ->
        RateLimiter.record_attempt(action, ip)
      end)

      # Should still be under limit (5)
      assert :ok = RateLimiter.check_rate_limit(action, ip)

      # Add 2 more to hit the limit
      RateLimiter.record_attempt(action, ip)
      RateLimiter.record_attempt(action, ip)

      # Now should be limited
      assert {:error, _} = RateLimiter.check_rate_limit(action, ip)
    end

    test "recording prunes stale attempts outside the active window", %{action: action, ip: ip} do
      cache_key = {action, ip}
      stale = System.system_time(:second) - 120

      :ets.insert(:auth_rate_limiter, {cache_key, [stale, stale - 1]})

      assert :ok = RateLimiter.record_attempt(action, ip)

      [{^cache_key, attempts}] = :ets.lookup(:auth_rate_limiter, cache_key)
      assert Enum.all?(attempts, &(&1 >= System.system_time(:second) - 60))
      assert length(attempts) == 1
    end
  end

  describe "check_rate_limit_and_record/3" do
    test "records the attempt only when under the limit", %{action: action, ip: ip} do
      assert :ok = RateLimiter.check_rate_limit_and_record(action, ip, limit: 2)
      assert :ok = RateLimiter.check_rate_limit_and_record(action, ip, limit: 2)
      assert {:error, _retry_after} = RateLimiter.check_rate_limit_and_record(action, ip, limit: 2)
    end

    test "counts concurrent bursts atomically", %{action: action, ip: ip} do
      results =
        1..10
        |> Task.async_stream(
          fn _ ->
            RateLimiter.check_rate_limit_and_record(action, ip, limit: 5, window_seconds: 60)
          end,
          max_concurrency: 10,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &(&1 == :ok)) == 5
      assert Enum.count(results, &match?({:error, _}, &1)) == 5
      assert {:error, _retry_after} = RateLimiter.check_rate_limit(action, ip, limit: 5)
    end
  end

  describe "clear_rate_limit/2" do
    test "clears rate limit for action/ip", %{action: action, ip: ip} do
      # Fill up the limit
      Enum.each(1..5, fn _ ->
        RateLimiter.record_attempt(action, ip)
      end)

      assert {:error, _} = RateLimiter.check_rate_limit(action, ip)

      # Clear it
      RateLimiter.clear_rate_limit(action, ip)

      # Should be ok now
      assert :ok = RateLimiter.check_rate_limit(action, ip)
    end

    test "succeeds even when no limit exists", %{action: action, ip: ip} do
      assert :ok = RateLimiter.clear_rate_limit(action, ip)
    end
  end

  describe "sliding window behavior" do
    test "retry_after decreases over time", %{action: action, ip: ip} do
      # Use a short window for testing
      Enum.each(1..3, fn _ ->
        RateLimiter.record_attempt(action, ip)
      end)

      # Should be limited with limit of 3
      {:error, retry_after1} = RateLimiter.check_rate_limit(action, ip, limit: 3)

      # Wait a bit
      Process.sleep(100)

      {:error, retry_after2} = RateLimiter.check_rate_limit(action, ip, limit: 3)

      # retry_after should be same or less (accounting for timing)
      assert retry_after2 <= retry_after1
    end
  end
end
