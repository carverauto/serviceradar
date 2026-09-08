defmodule ServiceRadar.Credentials.ProxmoxApiSmokeIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Credentials.ProxmoxApiSmoke

  @moduletag :integration

  if !ProxmoxApiSmoke.env_configured?() do
    @moduletag skip:
                 "set SERVICERADAR_PROXMOX_URL plus SERVICERADAR_PROXMOX_API_TOKEN or token id/secret env vars"
  end

  test "connects to Proxmox API with local env credentials" do
    assert {:ok, config} = ProxmoxApiSmoke.from_env()
    assert {:ok, result} = ProxmoxApiSmoke.run(config)

    assert result.schema == "serviceradar.proxmox_api_smoke.v1"
    assert is_map(result.version)
    assert is_integer(result.node_count)
    assert result.node_count >= 1

    refute inspect(result) =~ "PVEAPIToken"
    refute inspect(result) =~ "SERVICERADAR_PROXMOX"
  end
end
