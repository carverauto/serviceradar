defmodule ServiceRadar.Observability.WindowPageFollowTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.DeviceRiskIocExposure
  alias ServiceRadar.Observability.CapacityForecasting.Source, as: CapacitySource
  alias ServiceRadar.Observability.CapacityForecasting.Worker, as: CapacityWorker
  alias ServiceRadar.Observability.IpEnrichmentRefreshWorker
  alias ServiceRadar.Observability.NetflowInterfaceCacheRefreshWorker
  alias ServiceRadar.Observability.NetflowSecurityRefreshWorker
  alias ServiceRadar.Observability.SeasonalDisposition.Source, as: SeasonalSource
  alias ServiceRadar.Observability.SeasonalDisposition.Worker, as: SeasonalWorker

  defmodule WindowPageFixture do
    @moduledoc false

    def query_page(_query, opts) do
      case Keyword.get(opts, :cursor) do
        nil ->
          {:ok, %{rows: [endpoint_row("192.0.2.1")], next_cursor: "page-2"}}

        "page-2" ->
          {:ok, %{rows: [endpoint_row("192.0.2.2")], next_cursor: nil}}
      end
    end

    defp endpoint_row(ip), do: %{"src_endpoint_ip" => ip, "dst_endpoint_ip" => ip}
  end

  defmodule CapacityHistoryPageFixture do
    @moduledoc false
    @start ~U[2026-06-01 00:00:00Z]

    def query_page(_query, opts) do
      case Keyword.get(opts, :cursor) do
        nil ->
          {:ok, %{rows: history("device-a", "host-a"), next_cursor: "page-2"}}

        "page-2" ->
          {:ok, %{rows: history("device-b", "host-b"), next_cursor: nil}}
      end
    end

    defp history(device_id, host_id) do
      for hour <- 0..47 do
        %{
          "bucket" => DateTime.add(@start, hour * 3_600, :second),
          "device_id" => device_id,
          "host_id" => host_id,
          "avg_usage_percent" => 20.0 + hour
        }
      end
    end
  end

  defmodule SeasonalHistoryPageFixture do
    @moduledoc false

    def query_page(_query, opts) do
      case Keyword.get(opts, :cursor) do
        nil ->
          {:ok, %{rows: [profile_row("device-a")], next_cursor: "page-2"}}

        "page-2" ->
          {:ok, %{rows: [profile_row("device-b")], next_cursor: nil}}
      end
    end

    defp profile_row(series) do
      %{
        "series" => series,
        "dow" => 1,
        "hod" => 9,
        "sample_value" => 35.0,
        "bucket" => "2026-06-22T09:00:00Z",
        "robust_bucket_count" => 8,
        "center" => 35.0,
        "mad" => 2.0
      }
    end
  end

  @forecasted_at ~U[2026-06-12 12:00:00Z]

  test "interface pair discovery keeps the page after a full page" do
    pairs = fn _since, limit, after_pair ->
      page =
        case after_pair do
          nil -> [{"192.0.2.1", 1}]
          {"192.0.2.1", 1} -> [{"192.0.2.2", 2}]
          _ -> []
        end

      Enum.take(page, limit)
    end

    assert NetflowInterfaceCacheRefreshWorker.discover_interface_pairs(60, 1, pairs: pairs) ==
             [{"192.0.2.1", 1}, {"192.0.2.2", 2}]
  end

  test "interface pair discovery continues past a full page that normalizes to nothing" do
    pairs = fn _since, limit, after_pair ->
      page =
        case after_pair do
          nil -> [{"  ", 1}]
          {"  ", 1} -> [{"192.0.2.2", 2}]
          _ -> []
        end

      Enum.take(page, limit)
    end

    assert NetflowInterfaceCacheRefreshWorker.discover_interface_pairs(60, 1, pairs: pairs) ==
             [{"192.0.2.2", 2}]
  end

  test "threat candidate discovery keeps the page after a full page" do
    assert "last_5m"
           |> NetflowSecurityRefreshWorker.discover_candidate_ips(
             1,
             __MODULE__.WindowPageFixture
           )
           |> Enum.sort() == ["192.0.2.1", "192.0.2.2"]
  end

  test "ip enrichment discovery keeps the page after a full page" do
    assert "last_5m"
           |> IpEnrichmentRefreshWorker.discover_candidate_ips(
             1,
             __MODULE__.WindowPageFixture
           )
           |> Enum.sort() == ["192.0.2.1", "192.0.2.2"]
  end

  test "capacity history keeps the series that arrives on the next page" do
    source = %CapacitySource{
      name: "cpu_usage",
      resource_type: "cpu",
      metric_class: "cpu",
      metric_name: "usage_percent",
      query: "in:cpu_metrics time:last_180d window_scan:true limit:1",
      value_field: "avg_usage_percent",
      key_fields: ["device_id", "host_id"],
      label_fields: ["host_id", "device_id"],
      threshold: 80.0,
      model: "linear"
    }

    upsert_fun = fn attrs, _actor ->
      send(self(), {:upsert, attrs.resource_id})
      {:ok, attrs}
    end

    job = %Oban.Job{
      args: %{"trigger" => "cron"},
      inserted_at: @forecasted_at,
      scheduled_at: @forecasted_at
    }

    assert :ok =
             CapacityWorker.run(job,
               sources: [source],
               runner: __MODULE__.CapacityHistoryPageFixture,
               runtime_config_source: :none,
               upsert_fun: upsert_fun,
               emit_verdicts?: false,
               horizon_seconds: 24 * 3_600,
               min_points: 24
             )

    assert_received {:upsert, "device-a"}
    assert_received {:upsert, "device-b"}
  end

  test "seasonal history keeps the series that arrives on the next page" do
    source = %SeasonalSource{
      name: "cpu_seasonal",
      metric_class: "cpu",
      metric_name: "usage_percent",
      query: "in:timeseries_metrics window_scan:true limit:1"
    }

    assert {:ok, rows} =
             SeasonalWorker.edge_baseline_rows(source,
               runner: __MODULE__.SeasonalHistoryPageFixture
             )

    assert rows |> Enum.map(& &1.series_key) |> Enum.sort() == ["device-a", "device-b"]
  end

  test "hostile IOC flow scan keeps the row that arrives on the next offset page" do
    flows = [
      flow("sr:device-a", "192.0.2.1"),
      flow("sr:device-b", "192.0.2.2")
    ]

    assert {:ok, %{devices: 2, hits: 2}} =
             DeviceRiskIocExposure.evaluate(
               flow_limit: 1,
               query_flow_page: fn _opts, page_size, after_key ->
                 flows
                 |> Enum.drop_while(fn flow ->
                   after_key != nil and {flow.observed_at, flow.row_key} != after_key
                 end)
                 |> then(fn remaining -> if after_key, do: tl(remaining), else: remaining end)
                 |> Enum.take(page_size)
               end,
               query_findings: fn device_uids, _opts ->
                 Enum.map(device_uids, fn device_uid ->
                   %{
                     device_uid: device_uid,
                     cve_id: "CVE-2099-0001",
                     kev: false,
                     cvss: 7.5,
                     package: "nebula-transfer"
                   }
                 end)
               end,
               query_active_contribution_uids: fn -> [] end,
               open_alert?: fn _source_id -> false end,
               upsert_contribution: fn _contribution, _opts -> :ok end,
               emit_event: fn _payload -> :ok end,
               create_alert: fn _attrs -> {:ok, %{id: "alert-page"}} end
             )
  end

  defp flow(device_uid, hostile_ip) do
    %{
      device_uid: device_uid,
      agent_id: "agent-page",
      hostile_ip: hostile_ip,
      dst_ip: "198.51.100.10",
      dst_port: 443,
      comm: "nebula-transfer",
      cmdline: nil,
      observed_at: @forecasted_at,
      ioc_sources: ["fixture"],
      ioc_severity: 4,
      row_key: "#{device_uid},#{hostile_ip}"
    }
  end
end
