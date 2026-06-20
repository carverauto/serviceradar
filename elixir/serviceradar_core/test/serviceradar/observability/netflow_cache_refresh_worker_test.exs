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
end
