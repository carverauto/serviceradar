defmodule ServiceRadarWebNGWeb.TopologyLive.GodViewStreamState do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  require Logger

  # Layout diagnostics can be long; keep a single log line bounded.
  @client_stream_error_text_limit 2_000

  @default_decode_alert_ms 20.0
  @default_render_alert_ms 40.0

  def assign_stats(socket, params) when is_map(params) do
    pipeline_stats =
      params
      |> Map.get("pipeline_stats", %{})
      |> normalize_pipeline_stats()

    maybe_emit_client_perf_alert(params, pipeline_stats)

    socket
    |> assign(:stream_state, :ok)
    |> assign(:schema_version, Map.get(params, "schema_version", socket.assigns.schema_version))
    |> assign(:last_revision, Map.get(params, "revision"))
    |> assign(:last_generated_at, Map.get(params, "generated_at"))
    |> assign(:last_bytes, Map.get(params, "bytes"))
    |> assign(:last_node_count, Map.get(params, "node_count"))
    |> assign(:last_edge_count, Map.get(params, "edge_count"))
    |> assign(:last_renderer_mode, Map.get(params, "renderer_mode"))
    |> assign(:last_network_ms, Map.get(params, "network_ms"))
    |> assign(:last_decode_ms, Map.get(params, "decode_ms"))
    |> assign(:last_render_ms, Map.get(params, "render_ms"))
    |> assign(:last_bitmap_metadata, Map.get(params, "bitmap_metadata"))
    |> assign(:pipeline_stats, pipeline_stats)
    |> assign(:last_zoom_tier, Map.get(params, "zoom_tier"))
    |> assign(:last_zoom_mode, Map.get(params, "zoom_mode", socket.assigns.last_zoom_mode))
  end

  def assign_stats(socket, _params), do: socket

  def assign_retrying(socket) do
    stream_state = if topology_snapshot_seen?(socket), do: :ok, else: :retrying
    assign(socket, :stream_state, stream_state)
  end

  def assign_error(socket, params) when is_map(params) do
    log_client_stream_error(params)

    stream_state =
      cond do
        topology_snapshot_seen?(socket) ->
          :ok

        transient_startup_stream_error?(Map.get(params, "reason")) ->
          :retrying

        true ->
          :error
      end

    assign(socket, :stream_state, stream_state)
  end

  def assign_error(socket, _params), do: assign_error(socket, %{})

  # The client already knows exactly why the surface is blank -- the ELK diagnostic for a
  # layout error, or the RangeError with node ids for a render error -- and pushes it here as
  # `message`. Nothing read it. The only account of a blank topology was a UI box telling the
  # operator to check server logs and AGE data, neither of which knows anything about a
  # client-side exception, so the one description of the fault was discarded on arrival.
  defp log_client_stream_error(params) when is_map(params) do
    message = params |> Map.get("message") |> client_error_text()

    if message != "" do
      stack = params |> Map.get("stack") |> client_error_text()
      stack_suffix = if stack == "", do: "", else: " stack=#{stack}"

      Logger.warning(
        "god_view_client_stream_error reason=#{params |> Map.get("reason") |> client_error_text()} " <>
          "message=#{message}" <> stack_suffix
      )
    end

    :ok
  end

  defp client_error_text(value) when is_binary(value) do
    value |> String.trim() |> String.slice(0, @client_stream_error_text_limit)
  end

  defp client_error_text(nil), do: ""

  defp client_error_text(value) do
    value |> inspect() |> String.slice(0, @client_stream_error_text_limit)
  end

  defp maybe_emit_client_perf_alert(params, pipeline_stats) when is_map(params) and is_map(pipeline_stats) do
    decode_ms = numeric_ms(Map.get(params, "decode_ms"))
    render_ms = numeric_ms(Map.get(params, "render_ms"))
    node_count = numeric_count(Map.get(params, "node_count"))
    edge_count = numeric_count(Map.get(params, "edge_count"))

    if decode_ms > decode_alert_ms_threshold() do
      emit_client_perf_alert(
        "decode_ms_high",
        decode_ms,
        render_ms,
        node_count,
        edge_count,
        pipeline_stats
      )
    end

    if render_ms > render_alert_ms_threshold() do
      emit_client_perf_alert(
        "render_ms_high",
        decode_ms,
        render_ms,
        node_count,
        edge_count,
        pipeline_stats
      )
    end
  end

  defp maybe_emit_client_perf_alert(_params, _pipeline_stats), do: :ok

  defp emit_client_perf_alert(alert, decode_ms, render_ms, node_count, edge_count, pipeline_stats) do
    measurements = %{
      decode_ms: decode_ms,
      render_ms: render_ms,
      node_count: node_count,
      edge_count: edge_count
    }

    metadata = %{alert: alert, pipeline_stats: pipeline_stats}

    :telemetry.execute([:serviceradar, :god_view, :client, :perf_alert], measurements, metadata)

    Logger.warning(
      "god_view_client_perf_alert #{alert} decode_ms=#{decode_ms} render_ms=#{render_ms} " <>
        "nodes=#{node_count} edges=#{edge_count} pipeline_stats=#{inspect(pipeline_stats)}"
    )
  end

  defp decode_alert_ms_threshold do
    Application.get_env(
      :serviceradar_web_ng,
      :god_view_client_decode_alert_ms,
      @default_decode_alert_ms
    )
  end

  defp render_alert_ms_threshold do
    Application.get_env(
      :serviceradar_web_ng,
      :god_view_client_render_alert_ms,
      @default_render_alert_ms
    )
  end

  defp numeric_ms(value) when is_number(value), do: value * 1.0

  defp numeric_ms(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      _ -> 0.0
    end
  end

  defp numeric_ms(_), do: 0.0

  defp numeric_count(value) when is_integer(value), do: max(value, 0)

  defp numeric_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> max(parsed, 0)
      _ -> 0
    end
  end

  defp numeric_count(_), do: 0

  defp normalize_pipeline_stats(stats) when is_map(stats) do
    keys = [
      :raw_links,
      :unique_pairs,
      :final_edges,
      :final_direct,
      :final_inferred,
      :final_attachment,
      :edge_class_backbone,
      :edge_class_attachment,
      :edge_class_inferred,
      :edge_class_hosted,
      :edge_class_observed,
      :backbone_edge_count,
      :unresolved_endpoints
    ]

    Enum.reduce(keys, %{}, fn key, acc ->
      raw = Map.get(stats, key) || Map.get(stats, Atom.to_string(key))
      parsed = parse_pipeline_stat(raw)

      if is_integer(parsed), do: Map.put(acc, key, parsed), else: acc
    end)
  end

  defp normalize_pipeline_stats(_), do: %{}

  defp parse_pipeline_stat(raw) when is_integer(raw), do: raw

  defp parse_pipeline_stat(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {value, _} -> value
      :error -> nil
    end
  end

  defp parse_pipeline_stat(_), do: nil

  defp topology_snapshot_seen?(socket) do
    not is_nil(socket.assigns.last_revision) or
      not is_nil(socket.assigns.last_node_count) or
      not is_nil(socket.assigns.last_edge_count)
  end

  defp transient_startup_stream_error?(reason)
       when reason in [
              "snapshot_bootstrap_failed",
              "snapshot_error",
              "snapshot_unavailable",
              "join_failed",
              "channel_error",
              "channel_close"
            ], do: true

  defp transient_startup_stream_error?(_reason), do: false
end
