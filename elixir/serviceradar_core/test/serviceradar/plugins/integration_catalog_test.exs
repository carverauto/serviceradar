defmodule ServiceRadar.Plugins.IntegrationCatalogTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.IntegrationCatalog

  test "builds a catalog from the latest approved package descriptors" do
    packages = [
      package("example-plugin", "1.0.0", "example-old", "old-source"),
      package("example-plugin", "1.2.0-rc.1", "example-prerelease", "prerelease-source"),
      package("example-plugin", "1.2.0", "example-inventory", "example-inventory"),
      package("other-plugin", "2.0.0", "other-inventory", "other-inventory")
    ]

    assert {:ok, catalog} = IntegrationCatalog.from_packages(packages)

    assert catalog.credential_profiles
           |> Enum.map(& &1["provider"])
           |> Enum.sort() == ["example-inventory", "other-inventory"]

    profile = Enum.find(catalog.credential_profiles, &(&1["provider"] == "example-inventory"))
    assert profile["plugin_package_id"] == "package-example-plugin-1.2.0"
    assert profile["config_schema"]["properties"]["endpoint"]["format"] == "uri"
    assert profile["producer_schedule"]["schedule_id"] == "example-inventory.refresh"

    source = Enum.find(catalog.inventory_sources, &(&1["source"] == "other-inventory"))
    assert source["plugin_id"] == "other-plugin"
    assert source["documentation"]["path"] == "docs/configuration.md"
  end

  test "stable releases sort after prereleases with the same version core" do
    packages = [
      package("example-plugin", "1.2.0-rc.2", "prerelease-provider", "prerelease-source"),
      package("example-plugin", "1.2.0", "stable-provider", "stable-source")
    ]

    assert {:ok, catalog} = IntegrationCatalog.from_packages(packages)
    assert Enum.map(catalog.credential_profiles, & &1["provider"]) == ["stable-provider"]
  end

  test "rejects duplicate package claims instead of choosing an implicit winner" do
    packages = [
      package("first-plugin", "1.0.0", "shared-provider", "first-source"),
      package("second-plugin", "1.0.0", "shared-provider", "second-source")
    ]

    assert {:error, {:duplicate_plugin_provider, "shared-provider", plugin_ids}} =
             IntegrationCatalog.from_packages(packages)

    assert Enum.sort(plugin_ids) == ["first-plugin", "second-plugin"]
  end

  test "approved packages may declare any valid provider without a core registration" do
    assert {:ok, catalog} =
             IntegrationCatalog.from_packages([
               package("example-plugin", "1.0.0", "previously-unknown", "example-source")
             ])

    assert [%{"provider" => "previously-unknown"}] =
             Enum.map(catalog.credential_profiles, &Map.take(&1, ["provider"]))
  end

  test "package catalogs do not include native core descriptors" do
    assert {:ok, catalog} =
             IntegrationCatalog.from_packages([
               package("example-plugin", "1.0.0", "example-inventory", "example-source")
             ])

    providers = Enum.map(catalog.credential_profiles, & &1["provider"])
    assert "example-inventory" in providers
    refute "vulncheck" in providers
    refute "snmp" in providers
  end

  test "a schedule_ids profile carries every bound schedule with the first as primary" do
    base = package("example-plugin", "1.0.0", "example-inventory", "example-source")
    [refresh] = base.manifest["producer_schedules"]

    telemetry = %{
      refresh
      | "schedule_id" => "example-inventory.telemetry",
        "label" => "Collect example telemetry",
        "action_id" => "example-inventory.telemetry",
        "default_cadence_seconds" => 60,
        "min_cadence_seconds" => 30
    }

    manifest =
      base.manifest
      |> Map.put("producer_schedules", [refresh, telemetry])
      |> update_in(["integrations", "credential_profiles", Access.at(0), "provisioning"], fn p ->
        p
        |> Map.delete("schedule_id")
        |> Map.put("schedule_ids", ["example-inventory.refresh", "example-inventory.telemetry"])
      end)

    assert {:ok, catalog} = IntegrationCatalog.from_packages([%{base | manifest: manifest}])
    assert [profile] = catalog.credential_profiles

    assert profile["producer_schedule"]["schedule_id"] == "example-inventory.refresh"

    assert Enum.map(
             profile["producer_schedules"],
             &{&1["schedule_id"], &1["default_cadence_seconds"]}
           ) ==
             [{"example-inventory.refresh", 86_400}, {"example-inventory.telemetry", 60}]
  end

  test "a schedule_id profile lists its one schedule as producer_schedules" do
    assert {:ok, catalog} =
             IntegrationCatalog.from_packages([
               package("example-plugin", "1.0.0", "example-inventory", "example-source")
             ])

    assert [profile] = catalog.credential_profiles
    assert [schedule] = profile["producer_schedules"]
    assert schedule == profile["producer_schedule"]
  end

  defp package(plugin_id, version, provider, source) do
    schedule_id = "#{provider}.refresh"

    %{
      id: "package-#{plugin_id}-#{version}",
      plugin_id: plugin_id,
      version: version,
      config_schema: %{
        "type" => "object",
        "properties" => %{"endpoint" => %{"type" => "string", "format" => "uri"}}
      },
      manifest: %{
        "id" => plugin_id,
        "name" => "#{plugin_id} package",
        "version" => version,
        "entrypoint" => "run_check",
        "runtime" => "wasi-preview1",
        "outputs" => "serviceradar.plugin_result.v1",
        "capabilities" => [
          "get_config",
          "log",
          "submit_result",
          "producer-schedule:v1"
        ],
        "permissions" => %{"allowed_domains" => ["*"]},
        "resources" => %{
          "requested_memory_mb" => 32,
          "requested_cpu_ms" => 5_000,
          "max_open_connections" => 2
        },
        "producer_schedules" => [
          %{
            "schedule_id" => schedule_id,
            "label" => "Refresh #{provider}",
            "action_id" => schedule_id,
            "command_type" => "plugin.run_action",
            "default_cadence_seconds" => 86_400,
            "min_cadence_seconds" => 3_600,
            "max_cadence_seconds" => 2_592_000,
            "dispatch_scope" => "assignment",
            "credential_requirements" => %{
              "inventory_account" => %{
                "required" => true,
                "resolution_location" => "agent",
                "grants" => []
              }
            }
          }
        ],
        "integrations" => %{
          "documentation" => %{"path" => "docs/configuration.md"},
          "credential_profiles" => [
            %{
              "provider" => provider,
              "label" => "#{provider} provider",
              "auth_methods" => [
                %{
                  "id" => "username_password",
                  "label" => "Username and password",
                  "credential_kind" => "username_password",
                  "fields" => [
                    %{
                      "id" => "username",
                      "label" => "Username",
                      "control" => "text",
                      "required" => true,
                      "secret" => false,
                      "public" => true
                    },
                    %{
                      "id" => "password",
                      "label" => "Password",
                      "control" => "password",
                      "required" => true,
                      "secret" => true
                    }
                  ]
                }
              ],
              "purposes" => ["device_inventory"],
              "scope_types" => ["agent"],
              "provisioning" => %{
                "mode" => "producer_schedule",
                "schedule_id" => schedule_id,
                "credential_requirement" => "inventory_account"
              }
            }
          ],
          "inventory_sources" => [
            %{
              "source" => source,
              "label" => "#{source} source",
              "metadata_fields" => []
            }
          ]
        }
      }
    }
  end
end
