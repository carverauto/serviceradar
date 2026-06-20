defmodule ServiceRadar.Observability.NetflowCacheRefreshWorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.NetflowExporterCacheRefreshWorker
  alias ServiceRadar.Observability.NetflowInterfaceCacheRefreshWorker

  describe "scan_window_seconds/1" do
    test "defaults both cache refresh workers to a bounded recent window" do
      assert NetflowInterfaceCacheRefreshWorker.scan_window_seconds([]) == 1_800
      assert NetflowExporterCacheRefreshWorker.scan_window_seconds([]) == 1_800
    end

    test "accepts explicit seconds within the cap" do
      config = [scan_window_seconds: 900]

      assert NetflowInterfaceCacheRefreshWorker.scan_window_seconds(config) == 900
      assert NetflowExporterCacheRefreshWorker.scan_window_seconds(config) == 900
    end

    test "clamps legacy multi-day config to the max scan window" do
      config = [scan_window_days: 7]

      assert NetflowInterfaceCacheRefreshWorker.scan_window_seconds(config) == 3_600
      assert NetflowExporterCacheRefreshWorker.scan_window_seconds(config) == 3_600
    end
  end

  describe "observed_interface_pairs_from_rows/1" do
    test "extracts and deduplicates input/output ifIndex pairs from parsed flow rows" do
      rows = [
        %{
          sampler_address: " 10.1.0.1 ",
          ocsf_payload: %{
            "connection_info" => %{
              "input_snmp" => 10,
              "output_snmp" => "20"
            }
          }
        },
        %{
          sampler_address: "10.1.0.1",
          ocsf_payload: %{
            "connection_info" => %{
              "input_snmp" => "10",
              "output_snmp" => "not-an-index"
            }
          }
        },
        %{
          "sampler_address" => "10.1.0.2",
          "ocsf_payload" => %{
            connection_info: %{
              input_snmp: 30,
              output_snmp: 0
            }
          }
        }
      ]

      assert NetflowInterfaceCacheRefreshWorker.observed_interface_pairs_from_rows(rows) == [
               {"10.1.0.1", 10},
               {"10.1.0.1", 20},
               {"10.1.0.2", 30}
             ]
    end

    test "ignores rows without a sampler address or positive interface index" do
      rows = [
        %{sampler_address: "", ocsf_payload: %{"connection_info" => %{"input_snmp" => 10}}},
        %{sampler_address: "10.1.0.1", ocsf_payload: %{"connection_info" => %{}}},
        %{
          sampler_address: "10.1.0.1",
          ocsf_payload: %{"connection_info" => %{"input_snmp" => -1}}
        },
        %{
          sampler_address: "10.1.0.1",
          ocsf_payload: %{"connection_info" => %{"input_snmp" => "1.5"}}
        }
      ]

      assert NetflowInterfaceCacheRefreshWorker.observed_interface_pairs_from_rows(rows) == []
    end
  end
end
