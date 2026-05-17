defmodule ServiceRadarWebNG.Devices.ManualDeviceCreatorTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNG.Devices.ManualDeviceCreator

  defmodule HostnameResolverStub do
    @moduledoc false

    def resolve("missing-hostname.example"), do: {:error, :nxdomain}

    def resolve(hostname) when is_binary(hostname) do
      hash = :erlang.phash2(hostname, 65_025)
      third_octet = div(hash, 255)
      fourth_octet = rem(hash, 255)

      {:ok, "198.18.#{third_octet}.#{fourth_octet}"}
    end
  end

  setup do
    previous_resolver = Application.get_env(:serviceradar_web_ng, :device_hostname_resolver)
    Application.put_env(:serviceradar_web_ng, :device_hostname_resolver, HostnameResolverStub)

    on_exit(fn ->
      restore_app_env(:device_hostname_resolver, previous_resolver)
    end)

    user = AshTestHelpers.admin_user_fixture()

    {:ok, scope: Scope.for_user(user)}
  end

  test "resolves hostname-only devices and persists the resolved IP", %{scope: scope} do
    first_hostname = "manual-host-a-#{System.unique_integer([:positive])}.example"
    second_hostname = "manual-host-b-#{System.unique_integer([:positive])}.example"

    assert {:ok, first} =
             ManualDeviceCreator.create(scope, %{
               "hostname" => first_hostname,
               "ip" => "",
               "type" => "server",
               "tags" => ["source=test"]
             })

    assert {:ok, second} =
             ManualDeviceCreator.create(scope, %{
               hostname: second_hostname,
               ip: nil,
               type: "server",
               tags: []
             })

    assert first.hostname == first_hostname
    assert second.hostname == second_hostname
    assert first.ip =~ "198.18."
    assert second.ip =~ "198.18."
    assert first.ip != second.ip
    assert first.discovery_sources == ["manual"]
    assert first.tags == %{"source" => "test"}
    assert first.is_managed == true
    assert first.is_active == true
    assert second.is_managed == true
    assert second.is_active == true
  end

  test "does not add hostname-only devices when DNS resolution fails", %{scope: scope} do
    assert {:error, {:hostname_resolution_failed, "missing-hostname.example", :nxdomain}} =
             ManualDeviceCreator.create(scope, %{
               hostname: "missing-hostname.example",
               ip: "",
               type: "server",
               tags: []
             })
  end

  test "requires either a resolvable hostname or an IP address", %{scope: scope} do
    assert {:error, :missing_device_address} =
             ManualDeviceCreator.create(scope, %{hostname: "", ip: "", type: "server", tags: []})
  end

  test "keeps a user-provided IP when both hostname and IP are supplied", %{scope: scope} do
    assert {:ok, device} =
             ManualDeviceCreator.create(scope, %{
               hostname: "missing-hostname.example",
               ip: "203.0.113.10",
               type: "server",
               tags: []
             })

    assert device.hostname == "missing-hostname.example"
    assert device.ip == "203.0.113.10"
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_app_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
