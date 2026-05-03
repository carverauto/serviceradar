defmodule ServiceRadar.Dashboards.PackageImportTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Dashboards.PackageImport

  test "builds dashboard package attrs from manifest JSON and import metadata" do
    bytes = "dashboard wasm bytes"
    digest = sha256(bytes)

    manifest = %{
      "id" => "com.customer.wifi-map",
      "name" => "Customer WiFi Map",
      "version" => "1.2.3",
      "vendor" => "Customer",
      "renderer" => %{
        "kind" => "browser_wasm",
        "interface_version" => "dashboard-wasm-v1",
        "artifact" => "dashboard.wasm",
        "sha256" => digest
      },
      "data_frames" => [
        %{
          "id" => "sites",
          "query" => "in:wifi_sites",
          "encoding" => "arrow_ipc"
        }
      ],
      "capabilities" => ["srql.execute", "popup.open"],
      "settings_schema" => %{}
    }

    assert {:ok, attrs} =
             manifest
             |> Jason.encode!()
             |> PackageImport.attrs_from_json(
               wasm_object_key: "dashboards/com.customer.wifi-map/1.2.3/dashboard.wasm",
               source_type: :git,
               source_repo_url: "git@example.com:customer/dashboards.git",
               source_ref: "main",
               source_manifest_path: "united/dashboard.json",
               source_commit: "abc123",
               signature: %{"kind" => "cosign"},
               verification_status: "verified"
             )

    assert attrs.dashboard_id == "com.customer.wifi-map"
    assert attrs.name == "Customer WiFi Map"
    assert attrs.version == "1.2.3"
    assert attrs.renderer["sha256"] == digest
    assert attrs.content_hash == digest
    assert attrs.source_type == :git
    assert attrs.source_metadata == %{}
    assert attrs.verification_status == "verified"
  end

  test "verifies renderer artifact digest" do
    bytes = "dashboard wasm bytes"
    digest = sha256(bytes)
    renderer = %{"sha256" => digest}

    assert :ok = PackageImport.verify_artifact_digest(bytes, renderer)
    assert {:error, :digest_mismatch} = PackageImport.verify_artifact_digest("other", renderer)
  end

  test "builds package attrs for trusted browser module renderer" do
    bytes = "export default function mountDashboard() {}"
    digest = sha256(bytes)

    manifest = %{
      "id" => "com.customer.react-wifi-map",
      "name" => "React WiFi Map",
      "version" => "2.0.0",
      "renderer" => %{
        "kind" => "browser_module",
        "interface_version" => "dashboard-browser-module-v1",
        "artifact" => "renderer.js",
        "sha256" => digest,
        "trust" => "trusted",
        "exports" => ["default", "mountDashboard"]
      },
      "data_frames" => [
        %{
          "id" => "sites",
          "query" => "in:wifi_sites",
          "encoding" => "json_rows"
        }
      ],
      "capabilities" => ["srql.execute", "navigation.open", "popup.open"],
      "settings_schema" => %{}
    }

    assert :ok = PackageImport.verify_artifact_digest(bytes, manifest["renderer"])

    assert {:ok, attrs} =
             manifest
             |> Jason.encode!()
             |> PackageImport.attrs_from_json(
               wasm_object_key: "dashboards/com.customer.react-wifi-map/2.0.0/package.js",
               source_type: :upload,
               signature: %{"kind" => "local_upload"},
               verification_status: "verified"
             )

    assert attrs.renderer["kind"] == "browser_module"
    assert attrs.renderer["artifact"] == "renderer.js"
    assert attrs.renderer["trust"] == "trusted"
    assert attrs.content_hash == digest

    assert attrs.data_frames == [
             %{
               "id" => "sites",
               "query" => "in:wifi_sites",
               "encoding" => "json_rows",
               "required" => true
             }
           ]
  end

  test "returns manifest validation errors from import boundary" do
    assert {:error, errors} = PackageImport.attrs_from_json(~s({"id": "bad"}))
    assert Enum.any?(errors, &String.contains?(&1, "missing required field"))
  end

  defp sha256(bytes) do
    :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
  end
end
