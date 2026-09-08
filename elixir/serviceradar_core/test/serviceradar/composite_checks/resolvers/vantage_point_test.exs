defmodule ServiceRadar.CompositeChecks.Resolvers.VantagePointTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.Resolvers.VantagePoint
  alias ServiceRadar.Inventory.DeviceAgentAvailability

  @now ~U[2026-08-11 22:00:00.000000Z]

  defp input(max_age_seconds) do
    config =
      case max_age_seconds do
        nil -> %{"agent_id" => "agent-a"}
        seconds -> %{"agent_id" => "agent-a", "max_age_seconds" => seconds}
      end

    %CompositeCheckInput{key: "agent_a", kind: :vantage_point, config: config}
  end

  defp row(is_available, checked_at) do
    %DeviceAgentAvailability{
      device_uid: "device-1",
      agent_id: "agent-a",
      is_available: is_available,
      checked_at: checked_at
    }
  end

  test "available when the agent reached the device" do
    resolution = VantagePoint.resolve(input(900), row(true, DateTime.add(@now, -60)), @now)

    assert resolution.value == :available
    refute resolution.stale
    assert resolution.reason == nil
  end

  test "blocked when the agent got no positive response" do
    assert %{value: :blocked, stale: false} =
             VantagePoint.resolve(input(900), row(false, DateTime.add(@now, -60)), @now)
  end

  test "unknown with no_result when no row exists" do
    assert %{value: :unknown, reason: :no_result, observed_at: nil} =
             VantagePoint.resolve(input(900), nil, @now)
  end

  test "unknown with stale when the row is older than max_age" do
    checked_at = DateTime.add(@now, -1_000)
    resolution = VantagePoint.resolve(input(900), row(true, checked_at), @now)

    assert resolution.value == :unknown
    assert resolution.reason == :stale
    assert resolution.stale
    assert resolution.observed_at == checked_at
  end

  test "no max_age means the row is never stale" do
    assert %{value: :available, stale: false} =
             VantagePoint.resolve(input(nil), row(true, DateTime.add(@now, -1_000_000)), @now)
  end

  test "a row exactly at max_age is still fresh" do
    assert %{value: :available} =
             VantagePoint.resolve(input(900), row(true, DateTime.add(@now, -900)), @now)
  end

  test "a row one second past max_age is stale" do
    assert %{value: :unknown, reason: :stale} =
             VantagePoint.resolve(input(900), row(true, DateTime.add(@now, -901)), @now)
  end

  test "a row with no checked_at is stale when freshness is required" do
    assert %{value: :unknown, reason: :stale} =
             VantagePoint.resolve(input(900), row(true, nil), @now)
  end

  test "a blocked row that is stale resolves unknown, not blocked" do
    # Staleness must win. Reporting `blocked` from an old observation would let
    # a check assert isolation it has not actually observed recently.
    assert %{value: :unknown, reason: :stale} =
             VantagePoint.resolve(input(900), row(false, DateTime.add(@now, -5_000)), @now)
  end
end
