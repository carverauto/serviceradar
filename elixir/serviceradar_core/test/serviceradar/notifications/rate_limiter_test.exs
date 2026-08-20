defmodule ServiceRadar.Notifications.RateLimiterTest do
  @moduledoc """
  The rate limiter's pure window arithmetic and its no-budget short circuit.

  Neither touches the database - the short circuit deliberately answers before a
  round trip, because the overwhelming majority of channels configure no limit
  and a query per dispatch for them would be pure cost. The durable half is
  covered by `ServiceRadar.Notifications.RateLimiterDurabilityTest`.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.RateLimiter

  @channel_id "0195c0a0-0000-7000-8000-000000000001"

  defp at(iso), do: iso |> DateTime.from_iso8601() |> elem(1)

  describe "window arithmetic" do
    test "windows are minute aligned" do
      assert RateLimiter.window_start(at("2026-08-09T12:34:56.789Z")) ==
               at("2026-08-09T12:34:00Z")
    end

    test "an instant exactly on a boundary starts that window, not the previous one" do
      assert RateLimiter.window_start(at("2026-08-09T12:34:00Z")) == at("2026-08-09T12:34:00Z")
    end

    test "the next window is the wait a refused caller is handed" do
      assert RateLimiter.next_window_start(at("2026-08-09T12:34:56.789Z")) ==
               at("2026-08-09T12:35:00Z")
    end

    test "every instant in a minute maps to the same window" do
      # Two nodes with slightly different clocks must agree on which window they
      # are consuming, or "10 per minute" silently becomes "10 per node".
      window = RateLimiter.window_start(at("2026-08-09T12:34:00Z"))

      for second <- 0..59 do
        instant = DateTime.add(at("2026-08-09T12:34:00Z"), second, :second)
        assert RateLimiter.window_start(instant) == window
      end
    end

    test "the window is one minute" do
      assert RateLimiter.window_seconds() == 60
    end
  end

  describe "check_and_consume/4 without a configured budget" do
    setup do
      %{now: at("2026-08-09T12:34:56Z")}
    end

    test "a nil limit allows without a database round trip", %{now: now} do
      # No repo is running in this async case, so reaching the database at all
      # would raise. Passing is the assertion.
      assert RateLimiter.check_and_consume(@channel_id, nil, now) == :ok
    end

    test "a zero or negative limit allows", %{now: now} do
      assert RateLimiter.check_and_consume(@channel_id, 0, now) == :ok
      assert RateLimiter.check_and_consume(@channel_id, -1, now) == :ok
    end

    test "a non-integer limit allows rather than raising", %{now: now} do
      assert RateLimiter.check_and_consume(@channel_id, "10", now) == :ok
    end

    test "a channel id that is not a uuid allows rather than raising", %{now: now} do
      # Never suppress on ignorance: a malformed id is a caller bug, and a caller
      # bug must not become a deployment-wide page outage.
      assert RateLimiter.check_and_consume("not-a-uuid", 10, now) == :ok
    end

    test "a nil channel id allows", %{now: now} do
      assert RateLimiter.check_and_consume(nil, 10, now) == :ok
    end
  end

  describe "a concurrent first-row conflict" do
    test "an empty statement result is retried against a fresh snapshot" do
      now = at("2026-08-09T12:34:56Z")
      window = now |> RateLimiter.window_start() |> DateTime.to_naive()
      counter = :counters.new(1, [])

      query = fn _sql, _params ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 -> {:ok, %{rows: []}}
          _later -> {:ok, %{rows: [[1, window, false]]}}
        end
      end

      assert RateLimiter.check_and_consume(@channel_id, 1, now, query: query) ==
               {:wait, at("2026-08-09T12:35:00Z")}

      assert :counters.get(counter, 1) == 2
    end
  end

  describe "the limiter holds no process state" do
    test "there is no registered rate limiter process" do
      # This is the whole point of the module. `WebhookNotifier` kept its budget
      # in a GenServer, which reset on every restart and counted separately on
      # every replica. A process here would be the same bug wearing a new name.
      refute Process.whereis(RateLimiter)
    end
  end
end
