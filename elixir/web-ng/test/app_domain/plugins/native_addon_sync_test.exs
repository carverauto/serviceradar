defmodule ServiceRadarWebNG.Plugins.NativeAddonSyncTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Plugins.NativeAddonImporter
  alias ServiceRadarWebNG.Plugins.NativeAddonSync

  @moduletag :db_free

  test "unattended sync selects the newest import-ready release as one set" do
    addons = [
      candidate("anomaly", "0.3.1", "v1.4.24"),
      candidate("powerdns", "0.1.3", "v1.4.24"),
      candidate("anomaly", "0.3.0", "v1.4.23"),
      candidate("netprobe", "0.2.24", "v1.4.23")
    ]

    assert NativeAddonSync.candidates(addons) == Enum.take(addons, 2)
  end

  test "sync can explicitly select one historical release" do
    addons = [
      candidate("anomaly", "0.3.1", "v1.4.24"),
      candidate("anomaly", "0.3.0", "v1.4.23"),
      candidate("netprobe", "0.2.24", "v1.4.23")
    ]

    assert NativeAddonSync.candidates(addons, release_tag: "v1.4.23") == Enum.drop(addons, 1)
  end

  test "unattended sync does not fill a partial latest release from history" do
    addons = [
      candidate("anomaly", "0.3.1", "v1.4.24"),
      candidate("netprobe", "0.2.24", "v1.4.23")
    ]

    assert NativeAddonSync.candidates(addons, addon_ids: ["netprobe"]) == []
  end

  test "unattended sync skips an incomplete newest release entry" do
    addons = [
      candidate("anomaly", "0.3.1", "v1.4.24", false),
      candidate("anomaly", "0.3.0", "v1.4.23")
    ]

    assert NativeAddonSync.candidates(addons) == Enum.drop(addons, 1)
  end

  test "import_attrs forwards cached release and index_entry when the summary is unchanged" do
    release = %{"tag_name" => "v1.4.24", "name" => "ServiceRadar v1.4.24"}

    entry = %{
      "addon_id" => "anomaly",
      "version" => "0.3.1",
      "oci_ref" => "registry.example.test/serviceradar/anomaly:v1.4.24",
      "oci_digest" => "sha256:" <> String.duplicate("a", 64),
      "bundle_digest" => "sha256:" <> String.duplicate("b", 64)
    }

    addon = %{
      addon_id: "anomaly",
      version: "0.3.1",
      release_tag: "v1.4.24",
      repo_url: "https://github.com/example/serviceradar",
      oci_ref: entry["oci_ref"],
      oci_digest: entry["oci_digest"],
      bundle_digest: entry["bundle_digest"],
      release: release,
      index_entry: entry
    }

    attrs = NativeAddonSync.import_attrs(addon)
    assert attrs.release == release
    assert attrs.index_entry == entry

    mutated = %{addon | release_tag: "v1.4.25"}
    mutated_attrs = NativeAddonSync.import_attrs(mutated)
    refute Map.has_key?(mutated_attrs, :release)
    refute Map.has_key?(mutated_attrs, :index_entry)
  end

  test "list_release_addons populates cached release and index_entry for resolve_release_and_entry reuse" do
    defmodule OneShotReleaseClient do
      @moduledoc false

      def fetch_body(url, opts), do: get(url, opts)

      def get(url, _opts) do
        send(self(), {:github_request, url})

        cond do
          String.ends_with?(url, "/releases/tags/v1.4.24") ->
            {:ok,
             %Req.Response{
               status: 200,
               body: %{
                 "id" => 10,
                 "tag_name" => "v1.4.24",
                 "name" => "ServiceRadar v1.4.24",
                 "html_url" => "https://github.com/carverauto/serviceradar/releases/tag/v1.4.24",
                 "assets" => [
                   %{
                     "name" => "serviceradar-native-addon-index.json",
                     "browser_download_url" =>
                       "https://github.com/carverauto/serviceradar/releases/download/v1.4.24/serviceradar-native-addon-index.json"
                   }
                 ]
               }
             }}

          String.ends_with?(url, "/serviceradar-native-addon-index.json") ->
            {:ok,
             %Req.Response{
               status: 200,
               body:
                 Jason.encode!(%{
                   "schema_version" => 1,
                   "addons" => [
                     %{
                       "addon_id" => "anomaly",
                       "version" => "0.3.1",
                       "oci_ref" => "registry.carverauto.dev/serviceradar/anomaly:v1.4.24",
                       "oci_digest" => "sha256:" <> String.duplicate("a", 64),
                       "bundle_digest" => "sha256:" <> String.duplicate("b", 64),
                       "artifacts" => [
                         %{
                           "os" => "linux",
                           "arch" => "amd64",
                           "tarball_digest" => "sha256:" <> String.duplicate("c", 64),
                           "signature_digest" => "sha256:" <> String.duplicate("d", 64),
                           "tarball_sha256" => String.duplicate("e", 64)
                         }
                       ]
                     }
                   ]
                 })
             }}
        end
      end
    end

    previous = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import_http_client)
    Application.put_env(:serviceradar_web_ng, :first_party_plugin_import_http_client, OneShotReleaseClient)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:serviceradar_web_ng, :first_party_plugin_import_http_client)
      else
        Application.put_env(:serviceradar_web_ng, :first_party_plugin_import_http_client, previous)
      end
    end)

    assert {:ok, [addon]} =
             NativeAddonImporter.list_release_addons(
               %{"repo_url" => "https://github.com/carverauto/serviceradar"},
               "v1.4.24"
             )

    assert_received {:github_request, _release_url}
    assert_received {:github_request, _index_url}

    import_attrs = NativeAddonSync.import_attrs(addon)

    assert {:ok, resolved_release, resolved_entry} =
             NativeAddonImporter.resolve_release_and_entry(
               %{owner: "carverauto", repo: "serviceradar", repo_url: addon.repo_url},
               addon.release_tag,
               addon.addon_id,
               addon.version,
               import_attrs
             )

    assert resolved_release["tag_name"] == "v1.4.24"
    assert resolved_entry["addon_id"] == "anomaly"
    refute_received {:github_request, _extra_url}
  end

  defp candidate(addon_id, version, release_tag, import_ready? \\ true) do
    %{
      addon_id: addon_id,
      version: version,
      release_tag: release_tag,
      import_ready?: import_ready?
    }
  end
end
