defmodule ServiceRadar.Notifications.DispatcherTest do
  @moduledoc """
  The dispatcher's pure decision helper.

  `backoff_ms/3` is the only decision the dispatcher makes itself rather than
  delegating to a core, so it is the only part testable without a database - and
  it is worth testing directly, because a backoff that ignores a provider's
  `Retry-After` earns a longer ban and a backoff without jitter turns a fan-out
  failure into a synchronised retry storm.

  Everything else `ServiceRadar.Notifications.Dispatcher` does is loading,
  calling a pure core, and persisting. The cores have their own async suites;
  the loading and persisting are covered by
  `ServiceRadar.Notifications.DispatcherRoutingTest`, which needs a database.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.Dispatcher

  # A pinned "random" source, so the jitter is an input rather than a source of
  # flakiness. Both extremes are exercised: 0.0 is the un-jittered floor and 1.0
  # is the ceiling.
  defp no_jitter, do: fn -> 0.0 end
  defp full_jitter, do: fn -> 1.0 end

  describe "backoff_ms/3 exponential growth" do
    test "starts at the 30 second base and doubles per attempt" do
      assert Dispatcher.backoff_ms(1, nil, no_jitter()) == 30_000
      assert Dispatcher.backoff_ms(2, nil, no_jitter()) == 60_000
      assert Dispatcher.backoff_ms(3, nil, no_jitter()) == 120_000
      assert Dispatcher.backoff_ms(4, nil, no_jitter()) == 240_000
    end

    test "is capped at one hour rather than growing without bound" do
      assert Dispatcher.backoff_ms(20, nil, no_jitter()) == 3_600_000
    end

    test "an absurd attempt number does not build a bignum" do
      # The exponent is capped BEFORE `Integer.pow/2` runs. Without that, a row
      # whose attempt_count was somehow corrupted would compute 2^1_000_000 and
      # take the scheduler with it.
      assert Dispatcher.backoff_ms(1_000_000, nil, no_jitter()) == 3_600_000
    end

    test "a non-positive or non-integer attempt is treated as the first attempt" do
      assert Dispatcher.backoff_ms(0, nil, no_jitter()) == 30_000
      assert Dispatcher.backoff_ms(-3, nil, no_jitter()) == 30_000
      assert Dispatcher.backoff_ms(nil, nil, no_jitter()) == 30_000
    end
  end

  describe "backoff_ms/3 jitter" do
    test "adds up to 20 percent and never subtracts" do
      assert Dispatcher.backoff_ms(1, nil, full_jitter()) == 36_000
      assert Dispatcher.backoff_ms(2, nil, full_jitter()) == 72_000
    end

    test "the un-jittered value is always the floor" do
      # Jitter that could subtract would let a retry land before a
      # provider-supplied Retry-After, which is worse than useless: it earns a
      # longer ban from the destination that asked for the wait.
      for attempt <- 1..8, _sample <- 1..25 do
        floor_ms = Dispatcher.backoff_ms(attempt, nil, no_jitter())
        assert Dispatcher.backoff_ms(attempt) >= floor_ms
      end
    end

    test "the default source produces varied values" do
      samples = for _ <- 1..50, do: Dispatcher.backoff_ms(1)

      assert Enum.uniq(samples) != [30_000],
             "backoff without jitter synchronises a whole fan-out's retries"
    end
  end

  describe "backoff_ms/3 provider retry hints" do
    test "a retry_after hint raises the delay when it exceeds the exponential" do
      assert Dispatcher.backoff_ms(1, 90_000, no_jitter()) == 90_000
    end

    test "a retry_after hint below the exponential does not lower it" do
      # The hint is a floor, not an override: a destination saying "1s is fine"
      # does not license hammering it on the fourth failure.
      assert Dispatcher.backoff_ms(4, 1_000, no_jitter()) == 240_000
    end

    test "a hint longer than the cap is honoured rather than clamped" do
      # Discord and PagerDuty both publish waits longer than an hour under load.
      # They are telling the truth about their own quota.
      assert Dispatcher.backoff_ms(1, 7_200_000, no_jitter()) == 7_200_000
    end

    test "a zero, negative, or non-integer hint is ignored" do
      assert Dispatcher.backoff_ms(1, 0, no_jitter()) == 30_000
      assert Dispatcher.backoff_ms(1, -5, no_jitter()) == 30_000
      assert Dispatcher.backoff_ms(1, "soon", no_jitter()) == 30_000
    end
  end
end
