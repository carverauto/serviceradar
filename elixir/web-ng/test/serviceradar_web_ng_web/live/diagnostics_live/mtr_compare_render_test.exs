defmodule ServiceRadarWebNGWeb.DiagnosticsLive.MtrCompareRenderTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrCompare

  @moduletag :db_free

  test "renders a negative destination latency delta with its minus sign" do
    document =
      render_comparison(
        a_latency: 10_000.0,
        b_latency: 20_000.0,
        latency_delta: -10_000.0
      )

    assert metric_delta(document) == "-10.0ms"
  end

  test "renders a positive destination latency delta with its plus sign" do
    document =
      render_comparison(
        a_latency: 20_000.0,
        b_latency: 10_000.0,
        latency_delta: 10_000.0
      )

    assert metric_delta(document) == "+10.0ms"
  end

  test "renders an available zero destination RTT as zero milliseconds" do
    document =
      render_comparison(
        a_latency: 0.0,
        b_latency: 10_000.0,
        latency_delta: -10_000.0
      )

    assert window_a_value(document) == "0.0ms"
  end

  test "renders unavailable destination RTT and delta as dashes" do
    document =
      render_comparison(
        a_latency: nil,
        b_latency: 10_000.0,
        latency_delta: nil
      )

    assert window_a_value(document) == "-"
    assert metric_delta(document) == "-"
  end

  defp render_comparison(opts) do
    window_a = %{label: "Window A", start: ~U[2026-05-07 00:00:00Z], end: ~U[2026-05-07 06:00:00Z]}
    window_b = %{label: "Window B", start: ~U[2026-05-06 00:00:00Z], end: ~U[2026-05-06 06:00:00Z]}

    window_state = %{
      preset: "custom",
      window_a: window_a,
      window_b: window_b,
      target_filter: "",
      agent_filter: "",
      protocol: "",
      reached: ""
    }

    comparison = %{
      a: summary(window_a, Keyword.fetch!(opts, :a_latency)),
      b: summary(window_b, Keyword.fetch!(opts, :b_latency)),
      deltas: %{
        success_rate: 0.0,
        trace_count: 0,
        avg_destination_us: Keyword.fetch!(opts, :latency_delta),
        destination_loss_pct: 0.0,
        avg_hops: 0.0
      },
      agents: [],
      elapsed_aligned?: true
    }

    (&MtrCompare.render/1)
    |> render_component(
      flash: %{},
      current_scope: %{
        user: %{email: "operator@example.com", role: :operator, timezone: "Etc/UTC"}
      },
      page_path: "/diagnostics/mtr/compare",
      mode: "window",
      recent_traces: [],
      trace_a: nil,
      trace_b: nil,
      diff: [],
      error: nil,
      window_state: window_state,
      window_comparison: comparison
    )
    |> LazyHTML.from_fragment()
  end

  defp summary(window, latency) do
    Map.merge(window, %{
      trace_count: 1,
      reached_count: 1,
      failed_count: 0,
      success_rate: 100.0,
      avg_hops: 1.0,
      avg_destination_us: latency,
      destination_loss_pct: 0.0,
      endpoint_sample_count: 1,
      agent_count: 1,
      target_count: 1,
      timeline: [],
      route_signatures: []
    })
  end

  defp window_a_value(document) do
    document
    |> LazyHTML.query(
      "#mtr-compare-destination-latency [title='View Window A traces for Destination Latency'] .sr-mtr-value"
    )
    |> LazyHTML.text()
    |> String.trim()
  end

  defp metric_delta(document) do
    document
    |> LazyHTML.query("#mtr-compare-destination-latency .sr-mtr-metric-delta")
    |> LazyHTML.text()
    |> String.trim()
  end
end
