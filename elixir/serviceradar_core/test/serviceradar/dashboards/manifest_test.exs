defmodule ServiceRadar.Dashboards.ManifestTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Dashboards.Manifest

  @digest String.duplicate("a", 64)

  test "validates and normalizes a dashboard package manifest from JSON" do
    manifest = %{
      "schema_version" => 1,
      "id" => "com.united.wifi-map",
      "name" => "United WiFi Map",
      "version" => "1.0.0",
      "description" => "Customer WiFi map dashboard",
      "vendor" => "United Airlines",
      "renderer" => %{
        "kind" => "browser_wasm",
        "interface_version" => "dashboard-wasm-v1",
        "artifact" => "dashboard.wasm",
        "sha256" => @digest,
        "entrypoint" => "render",
        "exports" => ["render", "dispose"]
      },
      "data_frames" => [
        %{
          "id" => "sites",
          "query" => "in:wifi_sites ap_count:>0",
          "encoding" => "arrow_ipc",
          "limit" => 750,
          "fields" => ["site_code", "latitude", "longitude", "ap_count"],
          "coordinates" => %{
            "latitude" => "latitude",
            "longitude" => "longitude"
          }
        }
      ],
      "capabilities" => ["srql.execute", "popup.open", "navigation.open", "map.deck.render"],
      "settings_schema" => %{
        "type" => "object",
        "properties" => %{
          "default_query" => %{
            "type" => "string",
            "title" => "Default Query"
          }
        },
        "additionalProperties" => false
      },
      "source" => %{
        "repo" => "git@example.com:customer/dashboards.git",
        "ref" => "main"
      }
    }

    assert {:ok, parsed} = manifest |> Jason.encode!() |> Manifest.from_json()
    assert parsed.id == "com.united.wifi-map"
    assert parsed.name == "United WiFi Map"
    assert parsed.renderer["kind"] == "browser_wasm"
    assert parsed.renderer["interface_version"] == "dashboard-wasm-v1"
    assert parsed.renderer["artifact"] == "dashboard.wasm"
    assert parsed.renderer["sha256"] == @digest

    assert [%{"id" => "sites", "encoding" => "arrow_ipc", "limit" => 750, "required" => true}] =
             parsed.data_frames

    assert "srql.execute" in parsed.capabilities
    assert "map.deck.render" in parsed.capabilities
    assert parsed.settings_schema["type"] == "object"
  end

  test "rejects unsupported renderer capabilities and mutable package shape" do
    manifest = valid_manifest()

    bad_manifest =
      manifest
      |> Map.put("unexpected", true)
      |> put_in(["capabilities"], ["srql.execute", "network.fetch"])
      |> put_in(["renderer", "kind"], "javascript")
      |> put_in(["renderer", "interface_version"], "dashboard-wasm-v0")

    assert {:error, errors} = Manifest.from_map(bad_manifest)
    assert "manifest contains unsupported keys: unexpected" in errors
    assert "renderer.kind must be one of: browser_wasm (got javascript)" in errors

    assert "renderer.interface_version must be one of: dashboard-wasm-v1 (got dashboard-wasm-v0)" in errors

    assert "capabilities contain unsupported values: network.fetch" in errors
  end

  test "requires unique data frame ids and valid coordinate mappings" do
    manifest =
      put_in(valid_manifest(), ["data_frames"], [
        %{
          "id" => "sites",
          "query" => "in:wifi_sites",
          "encoding" => "json_rows",
          "coordinates" => %{"latitude" => " "}
        },
        %{"id" => "sites", "query" => "in:wifi_sites", "encoding" => "json_rows"}
      ])

    assert {:error, errors} = Manifest.from_map(manifest)

    assert "data_frames contain duplicate ids: sites" in errors

    assert "data_frames[0].coordinates must include latitude/longitude or geometry field names" in errors
  end

  test "validates settings schema with existing plugin config schema rules" do
    manifest =
      put_in(valid_manifest(), ["settings_schema"], %{
        "type" => "object",
        "properties" => %{"unsafe" => %{"type" => "string", "unknown" => true}}
      })

    assert {:error, errors} = Manifest.from_map(manifest)
    assert Enum.any?(errors, &String.contains?(&1, "properties.unsafe contains unsupported keys"))
  end

  defp valid_manifest do
    %{
      "id" => "com.example.network-map",
      "name" => "Network Map",
      "version" => "0.1.0",
      "renderer" => %{
        "kind" => "browser_wasm",
        "interface_version" => "dashboard-wasm-v1",
        "artifact" => "network-map.wasm",
        "sha256" => @digest
      },
      "data_frames" => [
        %{
          "id" => "sites",
          "query" => "in:wifi_sites",
          "encoding" => "json_rows"
        }
      ],
      "capabilities" => ["srql.execute"],
      "settings_schema" => %{}
    }
  end
end
