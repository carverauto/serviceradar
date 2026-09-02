defmodule ServiceRadarWebNGWeb.LogLive.NetflowRangeNavigationTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNGWeb.LogLive.Index

  @moduletag :db_free

  @start "2026-08-27T10:00:00Z"
  @first_end "2026-08-27T10:04:59.999999Z"
  @last_start "2026-08-27T10:15:00Z"
  @last_end "2026-08-27T10:19:59.999999Z"

  test "a valid range replaces every time token and opens Flow Explorer with the remaining state" do
    query =
      ~s(in:flows   src_ip:192.0.2.10 time:last_1h app:"Microsoft Teams" time:[2026-08-26T00:00:00Z,2026-08-26T01:00:00Z] sort:timestamp:desc limit:37)

    socket =
      socket(%{
        srql: %{query: query, page_path: "/observability/netflows"},
        limit: 99,
        netflow_compact?: true,
        netflow_talker_cidr: 16,
        netflow_compare_mode: "previous",
        netflow_geo_side: "src",
        netflow_sankey_prefix: 24,
        netflow_stack_mode: "talkers",
        netflow_graph_mode: "lines",
        netflow_view: "traffic"
      })

    params = selected_params(@start, @last_end)
    decoded = socket |> select_range(params) |> redirected_query()

    assert decoded == %{
             "compact" => "1",
             "compare" => "previous",
             "geo" => "src",
             "graph" => "lines",
             "q" =>
               ~s(in:flows src_ip:192.0.2.10 app:"Microsoft Teams" sort:timestamp:desc limit:37 time:[2026-08-27T10:00:00Z,2026-08-27T10:19:59.999999Z]),
             "sankey_prefix" => "24",
             "stack" => "talkers",
             "talker_cidr" => "16",
             "view" => "explorer"
           }

    assert length(Regex.scan(~r/(?:^|\s)time:/, decoded["q"])) == 1
    refute Map.has_key?(decoded, "limit")
  end

  test "a query without an SRQL limit preserves the current effective legacy URL limit" do
    socket = socket(%{srql: %{query: "in:flows time:last_1h protocol:tcp"}, limit: 73})
    decoded = socket |> select_range(selected_params(@start, @last_end)) |> redirected_query()

    assert decoded["limit"] == "73"
    assert decoded["view"] == "explorer"

    assert decoded["q"] ==
             "in:flows protocol:tcp time:[2026-08-27T10:00:00Z,2026-08-27T10:19:59.999999Z]"
  end

  test "time replacement is quote-aware and removes time aliases case-insensitively" do
    query =
      ~s(in:flows note:"keep time:inside and TimeFrame:inside" TIME:last_1h protocol:tcp TimeFrame:[2026-08-26T00:00:00Z,2026-08-26T01:00:00Z] time:last_6h)

    decoded =
      %{srql: %{query: query, page_path: "/observability/netflows"}}
      |> socket()
      |> select_range(selected_params(@start, @last_end))
      |> redirected_query()

    assert decoded["q"] ==
             ~s(in:flows note:"keep time:inside and TimeFrame:inside" protocol:tcp time:[2026-08-27T10:00:00Z,2026-08-27T10:19:59.999999Z])
  end

  test "the existing one-bucket action retains its view and canonical inclusive boundary" do
    decoded =
      socket()
      |> select_bucket(selected_params(@start, @first_end))
      |> redirected_query()

    assert decoded["q"] ==
             "in:flows sort:timestamp:desc limit:50 time:[2026-08-27T10:00:00Z,2026-08-27T10:04:59.999999Z]"

    assert decoded["view"] == "overview"
  end

  test "each rendered selector combination authorizes an exact current range" do
    eligible = [
      %{netflow_view: "overview", netflow_graph_mode: "lines"},
      %{netflow_view: "overview", netflow_graph_mode: "grid"},
      %{netflow_view: "traffic", netflow_graph_mode: "lines"},
      %{netflow_view: "traffic", netflow_graph_mode: "grid"},
      %{netflow_view: "overview", netflow_graph_mode: "stacked"},
      %{netflow_view: "overview", netflow_graph_mode: "stacked100"},
      %{netflow_view: "traffic", netflow_graph_mode: "stacked"},
      %{netflow_view: "traffic", netflow_graph_mode: "stacked100"},
      %{
        netflow_view: "traffic",
        netflow_graph_mode: "stacked",
        netflow_timeseries_stacked: empty_series(),
        netflow_protocol_activity: populated_series(),
        netflow_app_activity: empty_series()
      },
      %{
        netflow_view: "traffic",
        netflow_graph_mode: "stacked100",
        netflow_timeseries_stacked: empty_series(),
        netflow_protocol_activity: empty_series(),
        netflow_app_activity: populated_series()
      }
    ]

    for overrides <- eligible do
      decoded =
        overrides
        |> socket()
        |> select_range(selected_params(@start, @last_end))
        |> redirected_query()

      assert decoded["view"] == "explorer"
    end
  end

  test "Protocol activity alone opens Flow Explorer and preserves URL state" do
    socket =
      activity_only_socket(:protocol, %{
        srql: %{
          query: ~s(in:flows src_ip:192.0.2.10 time:last_1h app:"Microsoft Teams" sort:timestamp:desc),
          page_path: "/observability/netflows"
        },
        limit: 73,
        netflow_graph_mode: "stacked",
        netflow_stack_mode: "talkers"
      })

    decoded = socket |> select_range(selected_params(@start, @last_end)) |> redirected_query()

    assert decoded == %{
             "compact" => "1",
             "compare" => "previous",
             "geo" => "src",
             "graph" => "stacked",
             "limit" => "73",
             "q" =>
               ~s(in:flows src_ip:192.0.2.10 app:"Microsoft Teams" sort:timestamp:desc time:[2026-08-27T10:00:00Z,2026-08-27T10:19:59.999999Z]),
             "sankey_prefix" => "16",
             "stack" => "talkers",
             "talker_cidr" => "16",
             "view" => "explorer"
           }

    assert length(Regex.scan(~r/(?:^|\s)time:/, decoded["q"])) == 1
  end

  test "Application activity alone opens Flow Explorer and preserves SRQL limit precedence" do
    socket =
      activity_only_socket(:application, %{
        srql: %{
          query: "in:flows dst_ip:198.51.100.20 time:last_6h protocol:tcp limit:37",
          page_path: "/observability/netflows"
        },
        limit: 99,
        netflow_graph_mode: "stacked100",
        netflow_stack_mode: "ports"
      })

    decoded = socket |> select_range(selected_params(@start, @last_end)) |> redirected_query()

    assert decoded == %{
             "compact" => "1",
             "compare" => "previous",
             "geo" => "src",
             "graph" => "stacked100",
             "q" =>
               "in:flows dst_ip:198.51.100.20 protocol:tcp limit:37 time:[2026-08-27T10:00:00Z,2026-08-27T10:19:59.999999Z]",
             "sankey_prefix" => "16",
             "stack" => "ports",
             "talker_cidr" => "16",
             "view" => "explorer"
           }

    refute Map.has_key?(decoded, "limit")
    assert length(Regex.scan(~r/(?:^|\s)time:/, decoded["q"])) == 1
  end

  test "traffic Sankey rejects ranges even when activity cards are populated" do
    for activity_overrides <- [
          %{netflow_protocol_activity: populated_series(), netflow_app_activity: empty_series()},
          %{netflow_protocol_activity: empty_series(), netflow_app_activity: populated_series()},
          %{
            netflow_protocol_activity: populated_series(),
            netflow_app_activity: populated_series()
          }
        ] do
      overrides =
        Map.merge(
          %{
            netflow_view: "traffic",
            netflow_graph_mode: "sankey",
            netflow_timeseries_stacked: empty_series()
          },
          activity_overrides
        )

      assert %Socket{redirected: nil} =
               overrides |> socket() |> select_range(selected_params(@start, @last_end))
    end
  end

  test "hidden, non-temporal, and empty render guards reject otherwise canonical bounds" do
    empty = empty_series()

    ineligible = [
      %{active_tab: "logs", netflow_view: "overview", netflow_graph_mode: "lines"},
      %{netflow_view: "overview", netflow_graph_mode: "sankey"},
      %{netflow_view: "topology", netflow_graph_mode: "lines"},
      %{netflow_view: "talkers", netflow_graph_mode: "lines"},
      %{netflow_view: "explorer", netflow_graph_mode: "lines"},
      %{netflow_view: "all", netflow_graph_mode: "lines"},
      %{netflow_view: "overview", netflow_graph_mode: "lines", netflow_timeseries: %{points: []}},
      %{
        netflow_view: "overview",
        netflow_graph_mode: "stacked",
        netflow_timeseries_stacked: %{points: populated_series().points, keys: []}
      },
      %{
        netflow_view: "overview",
        netflow_graph_mode: "stacked100",
        netflow_timeseries_stacked: %{points: [], keys: ["tcp"]}
      },
      %{
        netflow_view: "traffic",
        netflow_graph_mode: "sankey",
        netflow_timeseries_stacked: empty,
        netflow_protocol_activity: %{points: populated_series().points, keys: []},
        netflow_app_activity: empty
      },
      %{
        netflow_view: "traffic",
        netflow_graph_mode: "sankey",
        netflow_timeseries_stacked: empty,
        netflow_protocol_activity: empty,
        netflow_app_activity: %{points: [], keys: ["dns"]}
      }
    ]

    for overrides <- ineligible do
      assert %Socket{redirected: nil} =
               overrides |> socket() |> select_range(selected_params(@start, @last_end))
    end
  end

  test "a range is rejected unless one visible selector rendered both canonical bounds" do
    non_rendered_end =
      socket(%{
        netflow_view: "overview",
        netflow_graph_mode: "stacked",
        netflow_timeseries_stacked: series_at([@start]),
        netflow_protocol_activity: empty_series(),
        netflow_app_activity: empty_series()
      })

    assert %Socket{redirected: nil} =
             select_range(non_rendered_end, selected_params(@start, @last_end))

    bounds_split_across_selectors =
      socket(%{
        netflow_view: "traffic",
        netflow_graph_mode: "stacked",
        netflow_timeseries_stacked: empty_series(),
        netflow_protocol_activity: series_at([@start]),
        netflow_app_activity: series_at([@last_start])
      })

    assert %Socket{redirected: nil} =
             select_range(bounds_split_across_selectors, selected_params(@start, @last_end))
  end

  test "invalid range classes and extra client authority fields never patch" do
    invalid = [
      %{},
      %{"start" => @start},
      %{"end" => @first_end},
      %{"start" => "bad", "end" => @first_end},
      %{"start" => @start, "end" => "bad"},
      %{"start" => @start, "end" => @start},
      %{"start" => "2026-08-27T10:15:00Z", "end" => @first_end},
      %{"start" => "2026-08-27T09:55:00Z", "end" => @first_end},
      %{"start" => @start, "end" => "2026-08-27T10:24:59.999999Z"},
      %{"start" => "2026-08-27T10:01:00Z", "end" => @last_end},
      %{"start" => @start, "end" => "2026-08-27T10:14:59.999999Z"},
      Map.put(selected_params(@start, @first_end), "query", "in:flows limit:1"),
      Map.put(selected_params(@start, @first_end), "destination", "/admin"),
      Map.put(selected_params(@start, @first_end), "field", "src_ip"),
      Map.put(selected_params(@start, @first_end), "source", "protocol")
    ]

    for params <- invalid do
      assert %Socket{redirected: nil} = select_range(socket(), params)
    end
  end

  defp select_range(socket, params) do
    assert {:noreply, socket} = Index.handle_event("netflow_range_selected", params, socket)
    socket
  end

  defp select_bucket(socket, params) do
    assert {:noreply, socket} = Index.handle_event("netflow_bucket", params, socket)
    socket
  end

  defp redirected_query(%Socket{redirected: {:live, :patch, %{to: "/observability/netflows?" <> query, kind: :push}}}) do
    URI.decode_query(query)
  end

  defp selected_params(start_time, end_time), do: %{"start" => start_time, "end" => end_time}

  defp activity_only_socket(kind, overrides) do
    {protocol_activity, app_activity} =
      case kind do
        :protocol -> {populated_series(), empty_series()}
        :application -> {empty_series(), populated_series()}
      end

    socket(
      Map.merge(
        %{
          netflow_view: "traffic",
          netflow_timeseries_stacked: empty_series(),
          netflow_protocol_activity: protocol_activity,
          netflow_app_activity: app_activity,
          netflow_compact?: true,
          netflow_talker_cidr: 16,
          netflow_compare_mode: "previous",
          netflow_geo_side: "src",
          netflow_sankey_prefix: 16
        },
        overrides
      )
    )
  end

  defp socket(overrides \\ %{}) do
    assigns =
      Map.merge(
        %{
          __changed__: %{},
          active_tab: "netflows",
          srql: %{query: "in:flows time:last_1h sort:timestamp:desc limit:50"},
          limit: 50,
          netflow_timeseries: %{bucket_seconds: 300, points: canonical_points()},
          netflow_timeseries_stacked: populated_series(),
          netflow_protocol_activity: populated_series(),
          netflow_app_activity: populated_series(),
          netflow_compact?: false,
          netflow_talker_cidr: nil,
          netflow_compare_mode: "off",
          netflow_geo_side: "dst",
          netflow_sankey_prefix: 24,
          netflow_stack_mode: "ports",
          netflow_graph_mode: "lines",
          netflow_view: "overview"
        },
        overrides
      )

    %Socket{
      assigns: assigns,
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }
  end

  defp canonical_points do
    [
      point(~U[2026-08-27 10:00:00Z], ~U[2026-08-27 10:05:00Z]),
      point(~U[2026-08-27 10:15:00Z], ~U[2026-08-27 10:20:00Z])
    ]
  end

  defp point(start_time, end_time) do
    %{bucket_start: start_time, bucket_end: end_time, bytes: 100}
  end

  defp populated_series do
    series_at([@start, @last_start])
  end

  defp series_at(starts) do
    %{points: Enum.map(starts, &%{"t" => &1, "tcp" => 100}), keys: ["tcp"]}
  end

  defp empty_series, do: %{points: [], keys: []}
end
