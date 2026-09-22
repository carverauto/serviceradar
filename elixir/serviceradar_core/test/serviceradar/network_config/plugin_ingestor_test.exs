defmodule ServiceRadar.NetworkConfig.PluginIngestorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkConfig.PluginIngestor

  @payload %{
    "status" => "OK",
    "labels" => %{"source" => "opentext-nom", "kind" => "running_config"},
    "details" =>
      Jason.encode!(%{
        "kind" => "running_config",
        "config_kind" => "running",
        "device_uid" => "sr:host01.example.com",
        "body" => "interface GigabitEthernet0/1\n ip address 192.0.2.1 255.255.255.0\n"
      })
  }

  test "supports running-config plugin results" do
    assert PluginIngestor.supports?(@payload)
    refute PluginIngestor.supports?(%{"labels" => %{"source" => "opentext-nom"}})
  end

  test "extracts device uid and body without emitting interface facts" do
    assert {:ok, attrs} = PluginIngestor.extract(@payload)
    assert attrs.device_uid == "sr:host01.example.com"
    assert attrs.source == "opentext-nom"
    assert attrs.config_kind == :running
    assert attrs.body =~ "GigabitEthernet0/1"
    refute Map.has_key?(attrs, :facts)
  end
end
