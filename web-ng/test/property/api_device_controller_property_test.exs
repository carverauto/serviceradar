defmodule ServiceRadarWebNG.ApiDeviceControllerPropertyTest do
  use ServiceRadarWebNG.DataCase, async: true
  use ExUnitProperties

  alias ServiceRadarWebNG.Api.DeviceController
  alias ServiceRadarWebNG.Generators.SRQLGenerators
  alias ServiceRadarWebNG.TestSupport.PropertyOpts

  defp devices_index_params do
    StreamData.fixed_map(%{
      "limit" => SRQLGenerators.untrusted_param_value(),
      "offset" => SRQLGenerators.untrusted_param_value(),
      "page" => SRQLGenerators.untrusted_param_value(),
      "search" => SRQLGenerators.untrusted_param_value(),
      "status" => SRQLGenerators.untrusted_param_value(),
      "poller_id" => SRQLGenerators.untrusted_param_value(),
      "device_type" => SRQLGenerators.untrusted_param_value()
    })
  end

  property "DeviceController.index/2 never crashes for untrusted query params" do
    check all(
            params <- devices_index_params(),
            extra <- SRQLGenerators.json_map(max_length: 4),
            max_runs: PropertyOpts.max_runs()
          ) do
      conn = Plug.Test.conn("GET", "/api/devices")
      conn = DeviceController.index(conn, Map.merge(extra, params))
      assert conn.status in [200, 400]
    end
  end

  property "DeviceController.show/2 never crashes for untrusted device_id" do
    check all(
            device_id <- SRQLGenerators.untrusted_param_value(),
            max_runs: PropertyOpts.max_runs()
          ) do
      conn = Plug.Test.conn("GET", "/api/devices/any")
      conn = DeviceController.show(conn, %{"device_id" => device_id})
      assert conn.status in [200, 400, 404]
    end
  end
end
