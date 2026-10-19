defmodule ServiceRadarWebNG.Topology.WorldOverlayFrameTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.WorldOverlayFrame

  @moduletag :db_free

  defp payload do
    now = DateTime.from_unix!(1_893_456_000_123_456, :microsecond)

    interval = %{
      previous_observed_at: now,
      earliest_observed_at: DateTime.add(now, 1, :microsecond),
      observed_at: DateTime.add(now, 2, :microsecond)
    }

    unknown = %{
      status: :unknown,
      animate: false,
      packets_per_second: nil,
      observed_packets_per_second: nil,
      observed_octets_per_second: nil,
      octets_per_second: nil,
      packet_observed_relations: 0,
      octet_observed_relations: 0,
      packet_interval: nil,
      octet_interval: nil
    }

    partial = %{
      unknown
      | status: :partial,
        animate: true,
        observed_packets_per_second: 12.5,
        observed_octets_per_second: 0,
        packet_observed_relations: 1,
        octet_observed_relations: 1,
        packet_interval: interval,
        octet_interval: interval
    }

    %{
      layout_version: "synthetic-layout",
      tile_id: "0/0/0",
      revision: "synthetic-tile",
      generation: 7,
      sampled_at: now,
      health: %{
        world_revision: "synthetic-world",
        tile_revision: "synthetic-selection",
        epoch: "0020000000000001",
        revision: 9_007_199_254_740_995,
        observation_sequence: 9_007_199_254_740_997,
        sampled_at: now,
        source: %{
          source_status: :refreshing,
          reconciling: true,
          pending: 4,
          last_read_at: now,
          reconciled_since: nil,
          observed: 2
        },
        glyphs:
          for(
            row <- 0..1,
            do: %{
              id: "synthetic-#{row}",
              counts: %{healthy: row, unavailable: 0, unknown: 2 - row, observed: row, total: 2}
            }
          )
      },
      flow: %{
        coverage: %{
          rendered_relations: 3,
          selected_relations: 2,
          candidates_examined: 9,
          requested_pairs: 4,
          queried_pairs: 3,
          omitted_pairs: 1,
          scan_complete: false
        },
        query: %{
          since: DateTime.shift(now, minute: -15),
          until: now,
          fresh_after: DateTime.shift(now, minute: -2),
          window_seconds: 900,
          freshness_seconds: 120,
          timeout_ms: 5000
        },
        edges: [
          %{
            id: "synthetic-edge",
            total_relations: 3,
            selected_relations: 2,
            eligibility: %{physical: 1, shared_interface: 1, unselected: 1},
            forward: partial,
            reverse: unknown
          }
        ]
      }
    }
  end

  test "matches the independently encoded browser wire including nulls, coverage and microseconds" do
    assert {:ok, bytes} = WorldOverlayFrame.encode(payload())

    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) ==
             "585f159b722ef636a89239b7914464ebcc95fd1432723b05cc053323850b1bc8"
  end

  test "bounds full tile replacement and refuses rows or values outside the protocol" do
    data = payload()

    maximum = %{
      data
      | health: %{data.health | glyphs: List.duplicate(hd(data.health.glyphs), 128)},
        flow: %{data.flow | edges: List.duplicate(hd(data.flow.edges), 512)}
    }

    assert {:ok, bytes} = WorldOverlayFrame.encode(maximum)
    assert byte_size(bytes) < 131_072

    assert {:error, :frame_budget} =
             WorldOverlayFrame.encode(%{
               maximum
               | flow: %{maximum.flow | edges: [hd(data.flow.edges) | maximum.flow.edges]}
             })

    assert {:error, :invalid_overlay_frame} =
             WorldOverlayFrame.encode(put_in(data, [:health, :source, :source_status], :invented))

    assert {:error, :invalid_overlay_frame} = WorldOverlayFrame.encode(%{data | generation: -1})
  end
end
