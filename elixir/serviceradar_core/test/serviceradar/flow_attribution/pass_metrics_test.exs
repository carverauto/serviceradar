defmodule ServiceRadar.FlowAttribution.PassMetricsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.FlowAttribution.PassMetrics
  alias ServiceRadar.Observability.MetricEnvelope

  @moduletag :db_free

  # Each warehouse reading by the table it reads.
  defp warehouse(sql) do
    cond do
      sql =~ "topology_overlap" -> {:ok, %{rows: [[0]]}}
      sql =~ "producer_rows" -> {:ok, %{rows: [[1]]}}
      sql =~ "partitions_meta" -> {:ok, %{rows: [[2]]}}
      sql =~ "flow_process_attribution_observations" -> {:ok, %{rows: [[4, 2400]]}}
      sql =~ "ocsf_network_activity" -> {:ok, %{rows: [[1234]]}}
    end
  end

  # Decoded by the same envelope decoder EventWriter's Metrics processor uses,
  # so a batch it cannot read fails here rather than vanishing in production.
  defp published_rows(result, duration_ms, by_rank, query) do
    parent = self()

    assert :ok =
             PassMetrics.report(result, duration_ms, by_rank,
               query: query,
               publish: fn subject, body -> send(parent, {:published, subject, body}) && :ok end,
               now: ~U[2026-10-04 12:00:00Z]
             )

    assert_received {:published, "metrics.flow_attribution", body}
    assert {:ok, rows} = MetricEnvelope.decode_rows(body)
    rows
  end

  defp value(rows, name, tags \\ %{}) do
    Enum.find_value(rows, fn row ->
      if row.metric_name == name and Enum.all?(tags, fn {k, v} -> row.tags[k] == v end),
        do: row.value
    end)
  end

  test "a pass publishes its duration, matches, stamps and the warehouse readings" do
    rows = published_rows({:ok, 7}, 850, %{0 => 4, 1 => 1, 2 => 1, 3 => 1, 5 => 1}, &warehouse/1)

    assert value(rows, "flow_attribution_pass_duration_ms", %{"outcome" => "ok"}) == 850.0
    assert value(rows, "flow_attribution_stamped") == 7.0
    assert value(rows, "flow_attribution_matches", %{"strategy" => "exact"}) == 4.0
    assert value(rows, "flow_attribution_matches", %{"strategy" => "node_snat"}) == 1.0
    assert value(rows, "flow_attribution_matches", %{"strategy" => "public_endpoint"}) == 2.0
    assert value(rows, "flow_attribution_flows_read") == 1234.0
    assert value(rows, "flow_attribution_observation_lag_seconds") == 4.0
    assert value(rows, "flow_attribution_observation_ingest_rate") == 20.0
    assert value(rows, "flow_attribution_live_partitions") == 2.0
    assert value(rows, "flow_attribution_diagnostic", %{"outcome" => "attributed"}) == 1.0
    assert Enum.all?(rows, &(&1.timestamp == ~U[2026-10-04 12:00:00.000000Z]))
  end

  test "an empty pass publishes one diagnostic outcome" do
    # {matches, sampled flows, producer rows, overlap, outcome}
    # Producer presence is decided before sampled flows, so neither side is
    # no_producer_rows. Overlap is queried only once both sides are present.
    cases = [
      {%{}, 0, 0, :skip, "no_producer_rows"},
      {%{}, 0, 4, :skip, "no_sampled_flows"},
      {%{}, 2, 4, 0, "no_topology_overlap"},
      {%{}, 2, 4, 1, "no_tuple_candidate"},
      {%{0 => 2}, 2, 4, :skip, "candidate_unstamped"}
    ]

    for {by_rank, flows, producer, overlap, outcome} <- cases do
      rows =
        published_rows({:ok, 0}, 10, by_rank, fn sql ->
          probe(sql, flows, producer, overlap)
        end)

      assert value(rows, "flow_attribution_diagnostic", %{"outcome" => outcome}) == 1.0
    end
  end

  # A failing pass is exactly when the metrics matter; an unavailable reading
  # must not take the rest of the report down with it.
  test "a failed pass still reports, without the readings the warehouse could not give" do
    rows =
      published_rows({:error, :connect_failed}, 120_000, %{}, fn _sql ->
        {:error, :connect_failed}
      end)

    assert value(rows, "flow_attribution_pass_duration_ms", %{"outcome" => "error"}) == 120_000.0
    assert value(rows, "flow_attribution_diagnostic", %{"outcome" => "error"}) == 1.0
    refute value(rows, "flow_attribution_stamped")
    refute value(rows, "flow_attribution_flows_read")
  end

  defp probe(sql, flows, producer, overlap) do
    cond do
      sql =~ "topology_overlap" ->
        if overlap == :skip,
          do: {:error, :overlap_not_expected},
          else: {:ok, %{rows: [[overlap]]}}

      sql =~ "producer_rows" ->
        {:ok, %{rows: [[producer]]}}

      sql =~ "partitions_meta" ->
        {:ok, %{rows: [[1]]}}

      sql =~ "flow_process_attribution_observations" ->
        {:ok, %{rows: [[1, 1]]}}

      sql =~ "ocsf_network_activity" ->
        {:ok, %{rows: [[flows]]}}

      true ->
        {:error, :unexpected_probe}
    end
  end
end
