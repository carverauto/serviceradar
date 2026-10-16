defmodule ServiceRadarWebNG.Topology.WorldOverlayFrame do
  @moduledoc """
  SRTO v1 telemetry for one immutable tile receipt, without JSON row payloads.

  Health glyphs and flow edges retain the native selection order used by Arrow.
  Nullable rates and microsecond timestamps preserve unknown/partial coverage.
  """

  @counts ~w(healthy unavailable unknown observed total)a
  @eligibility ~w(physical ineligible not_physical_evidence excluded_role missing_interface_binding shared_interface unselected)a
  @coverage ~w(rendered_relations selected_relations candidates_examined requested_pairs queried_pairs omitted_pairs)a
  @rates ~w(packets_per_second observed_packets_per_second observed_octets_per_second octets_per_second)a
  @times ~w(previous_observed_at earliest_observed_at observed_at)a
  @nil_time -9_223_372_036_854_775_808

  def encode(payload) do
    health = payload.health
    flow = payload.flow

    if length(health.glyphs) > 128 or length(flow.edges) > 512, do: throw(:frame_budget)

    body = [
      Enum.map(
        [payload.layout_version, payload.tile_id, payload.revision, health.world_revision, health.tile_revision],
        &text/1
      ),
      u64(payload.generation),
      Enum.map([health.epoch, health.revision, health.observation_sequence], &u64/1),
      timestamp(payload.sampled_at),
      timestamp(health.sampled_at),
      source(health.source),
      Enum.map(@coverage, &u32(Map.fetch!(flow.coverage, &1))),
      boolean(flow.coverage.scan_complete),
      Enum.map([:since, :until, :fresh_after], &timestamp(Map.fetch!(flow.query, &1))),
      Enum.map([:window_seconds, :freshness_seconds, :timeout_ms], &u32(Map.fetch!(flow.query, &1))),
      <<length(health.glyphs)::little-16, length(flow.edges)::little-16>>,
      Enum.map(health.glyphs, fn glyph -> Enum.map(@counts, &u64(Map.fetch!(glyph.counts, &1))) end),
      Enum.map(flow.edges, &edge/1)
    ]

    size = 12 + IO.iodata_length(body)

    if size <= 262_144,
      do: {:ok, IO.iodata_to_binary([<<"SRTO", 1, 0, 0::little-16, size::little-32>>, body])},
      else: {:error, :frame_budget}
  rescue
    _ in [ArgumentError, KeyError, FunctionClauseError, BadMapError] -> {:error, :invalid_overlay_frame}
  catch
    reason -> {:error, reason}
  end

  defp source(source) do
    [
      enum(source.source_status, [:stale, :seeding, :refreshing, :current]),
      boolean(source.reconciling),
      u32(source.pending),
      timestamp(source.last_read_at),
      timestamp(source.reconciled_since),
      nullable_count(Map.get(source, :observed)),
      nullable_count(Map.get(source, :total))
    ]
  end

  defp edge(edge) do
    [
      u32(edge.total_relations),
      u32(edge.selected_relations),
      Enum.map(@eligibility, &u32(Map.get(edge.eligibility, &1, 0))),
      direction(edge.forward),
      direction(edge.reverse)
    ]
  end

  defp direction(direction) do
    [
      enum(direction.status, [:unknown, :partial, :measured]),
      boolean(direction.animate),
      <<0::16>>,
      Enum.map(@rates, &rate(Map.fetch!(direction, &1))),
      u32(direction.packet_observed_relations),
      u32(direction.octet_observed_relations),
      interval(direction.packet_interval),
      interval(direction.octet_interval)
    ]
  end

  defp interval(nil), do: Enum.map(@times, fn _ -> timestamp(nil) end)
  defp interval(interval), do: Enum.map(@times, &timestamp(Map.fetch!(interval, &1)))
  defp nullable_count(nil), do: <<0, 0::little-64>>
  defp nullable_count(value), do: [<<1>>, u64(value)]
  defp rate(nil), do: <<0x7FF8_0000_0000_0000::little-64>>
  defp rate(value) when is_number(value) and value >= 0, do: <<value::little-float-64>>
  defp timestamp(nil), do: <<@nil_time::little-signed-64>>
  defp timestamp(%DateTime{} = value), do: <<DateTime.to_unix(value, :microsecond)::little-signed-64>>
  defp boolean(true), do: <<1>>
  defp boolean(false), do: <<0>>
  defp u32(value) when is_integer(value) and value in 0..4_294_967_295, do: <<value::little-32>>
  defp u64(value) when is_integer(value) and value in 0..18_446_744_073_709_551_615, do: <<value::little-64>>

  defp enum(value, values) do
    case Enum.find_index(values, &(&1 == value)) do
      nil -> throw(:invalid_overlay_frame)
      index -> <<index>>
    end
  end

  defp text(value) when is_binary(value) and byte_size(value) in 1..128 do
    if String.valid?(value) and not String.contains?(value, <<0>>),
      do: <<byte_size(value)::little-16, value::binary>>,
      else: throw(:invalid_overlay_frame)
  end
end
