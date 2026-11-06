defmodule ServiceRadarWebNG.Plugins.RecentReleaseCatalogTest do
  @moduledoc """
  Recent-release catalog listing for both first-party importers.

  One unreadable release must not hide the others: a draft (which a token with
  push access sees first, and whose `untagged-*` download path never resolves)
  is skipped, a published release whose index cannot be read is reported in
  `failed_releases`, and the listing fails only when every indexed release
  failed. The native add-on and Wasm importers share that contract, so each
  case runs against both.
  """

  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Plugins.FirstPartyImporter
  alias ServiceRadarWebNG.Plugins.ImportFailureMessages
  alias ServiceRadarWebNG.Plugins.NativeAddonImporter

  @moduletag :db_free

  @repo_url "https://github.com/example-org/release-fixture"
  @download_base "https://github.com/example-org/release-fixture/releases/download"

  defmodule FakeGitHub do
    @moduledoc false

    # Serves the release list and each release's index asset from the process
    # dictionary. An index URL missing from :catalog_indexes redirects, as
    # GitHub does, to a pre-signed URL that answers 404, so the failure text can
    # be checked for the signed query.
    def fetch_body(url, opts), do: get(url, opts)

    def get(url, _opts) do
      send(self(), {:requested, url})
      indexes = Process.get(:catalog_indexes, %{})

      cond do
        String.contains?(url, "/releases?per_page=") ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(Process.get(:catalog_releases)), headers: %{}}}

        Map.has_key?(indexes, url) ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(Map.fetch!(indexes, url)), headers: %{}}}

        String.starts_with?(url, "https://github.com/") ->
          signed = "https://objects.githubusercontent.com/fixture/index?X-Amz-Signature=0f1e2d3c4b5a"
          {:ok, %Req.Response{status: 302, body: "", headers: %{"location" => [signed]}}}

        true ->
          {:ok, %Req.Response{status: 404, body: "", headers: %{}}}
      end
    end
  end

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import_http_client)
    Application.put_env(:serviceradar_web_ng, :first_party_plugin_import_http_client, FakeGitHub)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:serviceradar_web_ng, :first_party_plugin_import_http_client)
      else
        Application.put_env(:serviceradar_web_ng, :first_party_plugin_import_http_client, previous)
      end
    end)
  end

  importers = [
    %{
      label: "native add-on",
      asset: "serviceradar-native-addon-index.json",
      importer: NativeAddonImporter,
      entries_key: :addons,
      index_key: "addons",
      id_key: "addon_id",
      id_field: :addon_id
    },
    %{
      label: "Wasm plugin",
      asset: "serviceradar-wasm-plugin-index.json",
      importer: FirstPartyImporter,
      entries_key: :plugins,
      index_key: "plugins",
      id_key: "plugin_id",
      id_field: :plugin_id
    }
  ]

  for importer <- importers do
    @importer importer

    describe "#{importer.label} recent-release listing" do
      test "a draft listed first does not hide the published releases" do
        importer = @importer
        draft_url = "#{@download_base}/untagged-5f3e9a0c1b2d4e6f7a80/#{importer.asset}"

        Process.put(:catalog_releases, [
          release(importer, 7003, "v9.3.0", draft: true, download_url: draft_url),
          release(importer, 7002, "v9.2.0")
        ])

        serve_index(importer, "v9.2.0")

        assert {:ok, summary} = list(importer)
        assert ids(importer, summary) == [{"fixture-v9.2.0", "v9.2.0"}]
        assert summary.failed_releases == []
        assert summary.indexed_releases == 1
        refute_received {:requested, ^draft_url}
      end

      test "a published release whose index fails is reported while the others list" do
        importer = @importer
        Process.put(:catalog_releases, [release(importer, 7002, "v9.2.0"), release(importer, 7001, "v9.1.0")])
        serve_index(importer, "v9.1.0")

        assert {:ok, summary} = list(importer)
        assert ids(importer, summary) == [{"fixture-v9.1.0", "v9.1.0"}]
        assert summary.indexed_releases == 1

        assert summary.failed_releases == [
                 %{
                   release_tag: "v9.2.0",
                   asset_name: importer.asset,
                   reason: {:release_index_unavailable, "v9.2.0", importer.asset, {:artifact_http_error, 404}}
                 }
               ]

        assert ImportFailureMessages.failed_releases_text(summary.failed_releases) ==
                 "1 release could not be read and is not listed: release v9.2.0 index #{importer.asset} " <>
                   "could not be loaded: plugin artifact download returned HTTP 404"
      end

      test "fails naming the first release and asset when every indexed release failed" do
        importer = @importer
        Process.put(:catalog_releases, [release(importer, 7002, "v9.2.0"), release(importer, 7001, "v9.1.0")])

        assert {:error, {:release_index_unavailable, "v9.2.0", asset, {:artifact_http_error, 404}} = reason} =
                 list(importer)

        assert asset == importer.asset

        assert ImportFailureMessages.reason_to_text(reason) ==
                 "release v9.2.0 index #{importer.asset} could not be loaded: plugin artifact download returned HTTP 404"
      end
    end
  end

  defp list(%{importer: NativeAddonImporter} = importer),
    do: NativeAddonImporter.list_recent_addons_with_summary(list_attrs(importer), 10)

  defp list(%{importer: FirstPartyImporter} = importer),
    do: FirstPartyImporter.list_recent_plugins_with_summary(list_attrs(importer), 10)

  defp list_attrs(importer), do: %{"repo_url" => @repo_url, "index_asset_name" => importer.asset}

  defp ids(importer, summary) do
    summary
    |> Map.fetch!(importer.entries_key)
    |> Enum.map(&{Map.fetch!(&1, importer.id_field), &1.release_tag})
  end

  defp release(importer, id, tag, opts \\ []) do
    %{
      "id" => id,
      "tag_name" => tag,
      "draft" => Keyword.get(opts, :draft, false),
      "html_url" => "https://github.com/example-org/release-fixture/releases/tag/#{tag}",
      "assets" => [
        %{
          "name" => importer.asset,
          "url" => "https://api.github.com/repos/example-org/release-fixture/releases/assets/#{id}",
          "browser_download_url" => Keyword.get(opts, :download_url, index_url(importer, tag))
        }
      ]
    }
  end

  defp serve_index(importer, tag) do
    index = %{importer.index_key => [%{importer.id_key => "fixture-#{tag}", "version" => String.trim_leading(tag, "v")}]}
    Process.put(:catalog_indexes, Map.put(Process.get(:catalog_indexes, %{}), index_url(importer, tag), index))
  end

  defp index_url(importer, tag), do: "#{@download_base}/#{tag}/#{importer.asset}"
end
