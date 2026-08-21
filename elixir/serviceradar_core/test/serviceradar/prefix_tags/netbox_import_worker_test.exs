defmodule ServiceRadar.PrefixTags.NetboxImportWorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.PrefixTags.NetboxImportWorker

  @page1 %{
    "count" => 3,
    "next" => "https://netbox.example/api/ipam/prefixes/?limit=2&offset=2",
    "results" => [
      %{
        "prefix" => "10.1.0.0/16",
        "site" => %{"slug" => "austin-dc", "name" => "Austin DC"},
        "role" => %{"slug" => "corp", "name" => "Corporate"},
        "tenant" => %{"slug" => "acme", "name" => "Acme"},
        "status" => %{"value" => "active"},
        "vrf" => %{"name" => "global"},
        "tags" => [%{"slug" => "iot", "name" => "IoT"}]
      },
      %{
        "prefix" => "10.1.2.0/24",
        "site" => %{"slug" => "austin-dc"},
        "role" => %{"slug" => "guest-wifi"},
        "status" => %{"value" => "active"},
        "tags" => []
      }
    ]
  }

  @page2 %{
    "count" => 3,
    "next" => nil,
    "results" => [
      %{
        "prefix" => "192.168.0.0/16",
        "site" => %{"slug" => "lab"},
        "status" => %{"value" => "reserved"},
        "tags" => [%{"slug" => "deprecated-vlan"}]
      }
    ]
  }

  describe "map_prefix_row/1" do
    test "maps NetBox dimensions to namespaced tags" do
      row =
        NetboxImportWorker.map_prefix_row(%{
          "prefix" => "10.1.2.0/24",
          "site" => %{"slug" => "austin-dc"},
          "role" => %{"slug" => "guest-wifi"},
          "tenant" => %{"slug" => "acme"},
          "status" => %{"value" => "active"},
          "tags" => [%{"slug" => "iot"}]
        })

      assert row.prefix == "10.1.2.0/24"
      assert row.site == "austin-dc"
      assert row.role == "guest-wifi"
      assert "site:austin-dc" in row.tags
      assert "role:guest-wifi" in row.tags
      assert "tenant:acme" in row.tags
      assert "status:active" in row.tags
      assert "netbox:tag:iot" in row.tags
      assert row.source == "netbox"
    end

    test "returns nil for missing prefix" do
      assert NetboxImportWorker.map_prefix_row(%{"tags" => []}) == nil
    end
  end

  describe "fetch_all_prefixes/2" do
    test "follows next pagination and validates count" do
      http_get = fn url, _opts ->
        cond do
          String.contains?(url, "/aggregates/") ->
            {:ok, %{status: 404, body: "not found"}}

          String.contains?(url, "offset=2") ->
            {:ok, %{status: 200, body: @page2}}

          true ->
            {:ok, %{status: 200, body: @page1}}
        end
      end

      creds = %{url: "https://netbox.example", token: "t", verify_ssl: true}

      assert {:ok, rows, meta} =
               NetboxImportWorker.fetch_all_prefixes(creds, http_get: http_get, page_limit: 2)

      assert length(rows) == 3
      assert meta.reported_count == 3
      assert Enum.any?(rows, &(&1.prefix == "10.1.2.0/24"))
      assert Enum.any?(rows, &(&1.prefix == "192.168.0.0/16"))

      guest = Enum.find(rows, &(&1.prefix == "10.1.2.0/24"))
      assert "role:guest-wifi" in guest.tags
      assert "site:austin-dc" in guest.tags
    end

    test "mid-pagination HTTP failure aborts without partial success" do
      http_get = fn url, _opts ->
        cond do
          String.contains?(url, "/aggregates/") ->
            {:ok, %{status: 404, body: "not found"}}

          String.contains?(url, "offset=2") ->
            {:ok, %{status: 500, body: "nope"}}

          true ->
            {:ok, %{status: 200, body: @page1}}
        end
      end

      creds = %{url: "https://netbox.example", token: "t", verify_ssl: true}

      assert {:error, {:http_status, 500}} =
               NetboxImportWorker.fetch_all_prefixes(creds, http_get: http_get)
    end

    test "count mismatch fails" do
      bad_page = @page1 |> Map.put("count", 99) |> Map.put("next", nil)

      http_get = fn url, _opts ->
        if String.contains?(url, "/aggregates/") do
          {:ok, %{status: 404, body: "not found"}}
        else
          {:ok, %{status: 200, body: bad_page}}
        end
      end

      creds = %{url: "https://netbox.example", token: "t", verify_ssl: true}

      assert {:error, {:count_mismatch, 2, 99}} =
               NetboxImportWorker.fetch_all_prefixes(creds, http_get: http_get)
    end
  end

  describe "resolve_credentials/1" do
    test "accepts injected credentials" do
      assert {:ok, %{url: "https://nb.example", token: "secret", verify_ssl: false}} =
               NetboxImportWorker.resolve_credentials(
                 credentials: %{
                   "url" => "https://nb.example/",
                   "token" => "secret",
                   "verify_ssl" => false
                 }
               )
    end

    test "missing token is no_credentials" do
      assert {:error, :no_credentials} =
               NetboxImportWorker.resolve_credentials(
                 credentials: %{"url" => "https://nb.example"}
               )
    end
  end

  describe "request_opts/2" do
    test "verify_ssl true keeps the named Finch pool" do
      opts = NetboxImportWorker.request_opts(5_000, true)
      assert Keyword.get(opts, :finch) == [name: ServiceRadar.Finch]
      refute Keyword.has_key?(opts, :connect_options)
    end

    test "verify_ssl false drops Finch and sets transport_opts (Req 0.6 contract)" do
      opts = NetboxImportWorker.request_opts(5_000, false)
      refute Keyword.has_key?(opts, :finch)
      assert Keyword.get(opts, :connect_options) == [transport_opts: [verify: :verify_none]]
    end
  end

  describe "validate_next_url/2" do
    test "allows same-origin pagination" do
      base = "https://netbox.example"
      next = "https://netbox.example/api/ipam/prefixes/?limit=2&offset=2"
      assert {:ok, ^next} = NetboxImportWorker.validate_next_url(next, base)
    end

    test "rejects cross-host next links (token exfiltration)" do
      base = "https://netbox.example"
      evil = "https://evil.example/api/ipam/prefixes/?limit=2"

      assert {:error, {:next_url_host_mismatch, ^evil}} =
               NetboxImportWorker.validate_next_url(evil, base)
    end

    test "rejects scheme changes" do
      assert {:error, {:next_url_host_mismatch, _}} =
               NetboxImportWorker.validate_next_url(
                 "http://netbox.example/api/ipam/prefixes/",
                 "https://netbox.example"
               )
    end

    test "nil next is ok" do
      assert {:ok, nil} = NetboxImportWorker.validate_next_url(nil, "https://netbox.example")
    end
  end

  describe "fetch_all_prefixes/2 next-host guard" do
    test "aborts when next points off-origin" do
      page = %{
        "count" => 2,
        "next" => "https://evil.example/steal",
        "results" => [
          %{"prefix" => "10.0.0.0/8", "tags" => []}
        ]
      }

      http_get = fn url, _opts ->
        if String.contains?(url, "/aggregates/") do
          {:ok, %{status: 404, body: "not found"}}
        else
          {:ok, %{status: 200, body: page}}
        end
      end

      creds = %{url: "https://netbox.example", token: "t", verify_ssl: true}

      assert {:error, {:next_url_host_mismatch, "https://evil.example/steal"}} =
               NetboxImportWorker.fetch_all_prefixes(creds, http_get: http_get)
    end
  end
end
