defmodule ServiceRadar.Observability.ThreatIntelFeedRefreshWorkerDbTest do
  @moduledoc false

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.ThreatIntelFeedRefreshWorker
  alias ServiceRadar.Observability.ThreatIntelIndicator
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    source = "feed-#{System.unique_integer([:positive])}.example.com"
    {:ok, actor: SystemActor.system(:threat_intel_feed_refresh_db_test), source: source}
  end

  test "a feed is written in a bounded number of statements, not one per indicator", ctx do
    body = feed_body(cidrs(600))

    {count, inserts} = counting_indicator_inserts(fn -> ingest(body, ctx) end)

    assert count == 600
    assert length(stored(ctx)) == 600
    assert inserts in 1..3, "expected a few batched INSERTs, got #{inserts}"
  end

  test "re-ingesting a feed refreshes expiry and keeps first-seen", ctx do
    body = feed_body(cidrs(3))
    first_now = ~U[2026-01-01 00:00:00.000000Z]
    later_now = ~U[2026-01-02 00:00:00.000000Z]

    ingest(body, ctx, first_now)
    ingest(body, ctx, later_now)

    rows = stored(ctx)
    assert length(rows) == 3

    for row <- rows do
      assert DateTime.compare(row.first_seen_at, first_now) == :eq
      assert DateTime.compare(row.last_seen_at, later_now) == :eq
      assert DateTime.compare(row.expires_at, DateTime.add(later_now, 3_600, :second)) == :eq
    end
  end

  test "one indicator written two ways is stored once", ctx do
    body = feed_body(["192.0.2.7", "192.0.2.7/32", "# comment", "", "not-a-cidr"])

    assert ingest(body, ctx) == 1
    assert [%{indicator: "192.0.2.7/32"}] = stored(ctx)
  end

  defp ingest(body, ctx, now \\ DateTime.utc_now()) do
    ThreatIntelFeedRefreshWorker.ingest_feed_body(body, ctx.source,
      actor: ctx.actor,
      now: now,
      expires_at: DateTime.add(now, 3_600, :second)
    )
  end

  defp stored(ctx) do
    ThreatIntelIndicator
    |> Ash.Query.filter(source == ^ctx.source)
    |> Ash.read!(actor: ctx.actor)
  end

  # Synthetic host indicators drawn from the three documentation ranges.
  @documentation_nets ["192.0.2", "198.51.100", "203.0.113"]

  defp cidrs(n) do
    for i <- 0..(n - 1), do: "#{Enum.at(@documentation_nets, div(i, 254))}.#{rem(i, 254) + 1}/32"
  end

  defp feed_body(lines), do: Enum.join(["# synthetic feed" | lines], "\n")

  defp counting_indicator_inserts(fun) do
    handler_id = "threat-intel-insert-count-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:service_radar, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if self() == test_pid and
               String.starts_with?(query, ~s(INSERT INTO "platform"."threat_intel_indicators")) do
            send(test_pid, :indicator_insert)
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain(:indicator_insert, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain(message, count) do
    receive do
      ^message -> drain(message, count + 1)
    after
      0 -> count
    end
  end
end
