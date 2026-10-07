defmodule ServiceRadarWebNGWeb.AshDomainsTest do
  use ExUnit.Case, async: true

  @moduletag :db_free

  test "serviceradar_core ash_domains config includes NetworkConfig and NetworkChanges" do
    domains = Application.get_env(:serviceradar_core, :ash_domains, [])
    assert ServiceRadar.NetworkConfig in domains
    assert ServiceRadar.NetworkChanges in domains
  end

  test "serviceradar_web_ng ash_domains config includes NetworkConfig and NetworkChanges" do
    domains = Application.get_env(:serviceradar_web_ng, :ash_domains, [])
    assert ServiceRadar.NetworkConfig in domains
    assert ServiceRadar.NetworkChanges in domains
  end

  test "web-ng ash_domains configuration includes all required core domains" do
    core_domains = Application.get_env(:serviceradar_core, :ash_domains, [])

    for domain <- [ServiceRadar.NetworkConfig, ServiceRadar.NetworkChanges] do
      assert domain in core_domains, "missing #{inspect(domain)} from :serviceradar_core :ash_domains"
    end
  end
end
