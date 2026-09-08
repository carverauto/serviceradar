defmodule ServiceRadar.Credentials.ProxmoxApiSmokeTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.ProxmoxApiSmoke

  test "from_env builds token header from token id and secret" do
    env = %{
      "SERVICERADAR_PROXMOX_URL" => "pve-a.example",
      "SERVICERADAR_PROXMOX_TOKEN_ID" => "root@pam!serviceradar",
      "SERVICERADAR_PROXMOX_TOKEN_SECRET" => "secret",
      "SERVICERADAR_PROXMOX_INSECURE_SKIP_VERIFY" => "true",
      "SERVICERADAR_PROXMOX_TIMEOUT_MS" => "45000"
    }

    assert {:ok, config} = ProxmoxApiSmoke.from_env(env: &Map.get(env, &1))

    assert config.base_url == "https://pve-a.example:8006"
    assert config.api_token == "PVEAPIToken=root@pam!serviceradar=secret"
    assert config.insecure_skip_verify == true
    assert config.timeout_ms == 45_000
  end

  test "run calls version and nodes without exposing token in result" do
    config = %{
      base_url: "https://pve-a.example:8006",
      api_token: "PVEAPIToken=root@pam!serviceradar=secret",
      timeout_ms: 30_000,
      insecure_skip_verify: true
    }

    request = fn url, headers, opts, _config ->
      send(self(), {:request, url, headers, opts})

      cond do
        String.ends_with?(url, "/api2/json/version") ->
          {:ok, %{status: 200, body: %{"data" => %{"version" => "8.2.2"}}}}

        String.ends_with?(url, "/api2/json/nodes") ->
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => [
                 %{"node" => "pve-a", "status" => "online", "ticket" => "must-not-leak"}
               ]
             }
           }}
      end
    end

    assert {:ok, result} = ProxmoxApiSmoke.run(config, request: request)

    assert_receive {:request, "https://pve-a.example:8006/api2/json/version", headers, opts}
    assert {"authorization", "PVEAPIToken=root@pam!serviceradar=secret"} in headers
    assert opts[:connect_options][:transport_opts] == [verify: :verify_none]

    assert_receive {:request, "https://pve-a.example:8006/api2/json/nodes", _headers, _opts}

    assert result.schema == "serviceradar.proxmox_api_smoke.v1"
    assert result.version == %{"version" => "8.2.2"}
    assert result.node_count == 1
    assert result.nodes == [%{"node" => "pve-a", "status" => "online"}]
    refute inspect(result) =~ "secret"
    refute inspect(result) =~ "must-not-leak"
  end
end
