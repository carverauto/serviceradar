defmodule ServiceRadar.PrefixTags.IntegrationTest do
  @moduledoc """
  Integration coverage for prefix-tag datasets on a disposable srql-fixtures database.

  Covers:
  - Ash Snapshot / PrefixTag lifecycle (create, promote, list_active, supersede)
  - NetBox importer promotion using fixture HTTP responses (no live NetBox)
  - Loader reload from CNPG into the in-memory Store
  - LPM equivalence against a SQL `inet <<= cidr ORDER BY masklen DESC` oracle

  Run through the guarded Bazel lifecycle, or follow
  `.agents/skills/srql-fixtures-db-tests/SKILL.md` to create a codex_* scratch database before a
  focused Mix invocation.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.PrefixTags.Loader
  alias ServiceRadar.PrefixTags.NetboxImportWorker
  alias ServiceRadar.PrefixTags.PrefixTag
  alias ServiceRadar.PrefixTags.Snapshot
  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadar.Repo

  @moduletag :integration
  @moduletag timeout: 120_000

  @system SystemActor.system(:prefix_tags_integration_test)

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

  setup do
    Store.clear()

    on_exit(fn ->
      Store.clear()
    end)

    :ok
  end

  describe "Ash Snapshot + PrefixTag lifecycle" do
    test "create, promote, list_active, and supersede through Ash" do
      assert {:ok, building} =
               Snapshot.create(
                 %{
                   source: "manual",
                   status: "building",
                   is_active: false,
                   record_count: 0,
                   metadata: %{"test" => true}
                 },
                 actor: @system
               )

      assert building.status == "building"
      assert building.is_active == false

      assert {:ok, tag} =
               PrefixTag.create(
                 %{
                   snapshot_id: building.id,
                   prefix: "10.50.0.0/16",
                   tags: ["manual:lab", "site:test"],
                   site: "test",
                   role: "lab"
                 },
                 actor: @system
               )

      assert tag.prefix == "10.50.0.0/16"
      assert "manual:lab" in List.wrap(tag.tags)

      assert {:ok, active} =
               Snapshot.promote(building, %{record_count: 1}, actor: @system)

      assert active.status == "active"
      assert active.is_active == true
      assert active.record_count == 1
      assert active.promoted_at

      assert {:ok, fetched} =
               Snapshot.active_for_source(%{source: "manual"}, actor: @system)

      assert fetched.id == active.id

      assert {:ok, page} = PrefixTag.list_active(%{}, actor: @system)
      tags = page_results(page)
      assert Enum.any?(tags, &(&1.id == tag.id))

      # Second generation: supersede previous before promoting a new active
      # (partial unique index enforces one active snapshot per source).
      assert {:ok, next_building} =
               Snapshot.create(
                 %{
                   source: "manual",
                   status: "building",
                   is_active: false,
                   record_count: 0
                 },
                 actor: @system
               )

      assert {:ok, _} =
               PrefixTag.create(
                 %{
                   snapshot_id: next_building.id,
                   prefix: "10.50.1.0/24",
                   tags: ["manual:lab-v2"]
                 },
                 actor: @system
               )

      assert {:ok, superseded} =
               active
               |> Ash.Changeset.for_update(:supersede, %{}, actor: @system)
               |> Ash.update()

      assert superseded.status == "superseded"
      assert superseded.is_active == false

      assert {:ok, next_active} =
               Snapshot.promote(next_building, %{record_count: 1}, actor: @system)

      assert next_active.is_active == true

      assert {:ok, current} =
               Snapshot.active_for_source(%{source: "manual"}, actor: @system)

      assert current.id == next_active.id
    end

    test "viewer cannot create prefix tags" do
      assert {:ok, building} =
               Snapshot.create(
                 %{source: "manual", status: "building", is_active: false, record_count: 0},
                 actor: @system
               )

      viewer = %{id: "viewer-1", email: "viewer@example.test", role: :viewer}

      assert {:error, %Ash.Error.Forbidden{}} =
               PrefixTag.create(
                 %{
                   snapshot_id: building.id,
                   prefix: "10.0.0.0/8",
                   tags: ["nope"]
                 },
                 actor: viewer
               )
    end
  end

  describe "NetBox importer fixtures → promote_snapshot" do
    test "paginated fixture fetch + promote writes active snapshot and prefix rows" do
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

      creds = %{url: "https://netbox.example", token: "fixture-token", verify_ssl: true}

      assert {:ok, rows, meta} =
               NetboxImportWorker.fetch_all_prefixes(creds, http_get: http_get, page_limit: 2)

      assert length(rows) == 3
      assert meta.reported_count == 3

      assert :ok = NetboxImportWorker.promote_snapshot(creds.url, rows, meta)

      assert {:ok, snap} =
               Snapshot.active_for_source(%{source: "netbox"}, actor: @system)

      assert snap.status == "active"
      assert snap.is_active == true
      assert snap.record_count == 3
      assert snap.source_url == "https://netbox.example"
      assert is_binary(snap.source_sha256) and snap.source_sha256 != ""

      assert {:ok, page} = PrefixTag.by_snapshot(%{snapshot_id: snap.id}, actor: @system)
      tags = page_results(page)
      assert length(tags) == 3

      guest = Enum.find(tags, &(&1.prefix == "10.1.2.0/24"))
      assert guest
      assert "role:guest-wifi" in List.wrap(guest.tags)
      assert "site:austin-dc" in List.wrap(guest.tags)

      lab = Enum.find(tags, &(&1.prefix == "192.168.0.0/16"))
      assert "netbox:tag:deprecated-vlan" in List.wrap(lab.tags)
    end

    test "second promote supersedes the previous active netbox snapshot" do
      rows_v1 = [
        %{prefix: "10.0.0.0/8", tags: ["netbox:tag:v1"], source: "netbox", site: "a"}
      ]

      rows_v2 = [
        %{prefix: "10.0.0.0/8", tags: ["netbox:tag:v2"], source: "netbox", site: "a"},
        %{prefix: "10.1.0.0/16", tags: ["netbox:tag:v2-narrow"], source: "netbox", site: "a"}
      ]

      assert :ok = NetboxImportWorker.promote_snapshot("https://nb.example/v1", rows_v1, %{})

      assert {:ok, first} =
               Snapshot.active_for_source(%{source: "netbox"}, actor: @system)

      assert first.record_count == 1

      assert :ok = NetboxImportWorker.promote_snapshot("https://nb.example/v2", rows_v2, %{})

      assert {:ok, second} =
               Snapshot.active_for_source(%{source: "netbox"}, actor: @system)

      assert second.id != first.id
      assert second.record_count == 2
      assert second.source_url == "https://nb.example/v2"

      assert {:ok, reloaded} = Snapshot.by_id(%{id: first.id}, actor: @system)
      assert reloaded.is_active == false
      assert reloaded.status == "superseded"
    end

    test "mid-pagination failure never promotes a partial snapshot" do
      http_get = fn url, _opts ->
        cond do
          String.contains?(url, "/aggregates/") ->
            {:ok, %{status: 404, body: "not found"}}

          String.contains?(url, "offset=2") ->
            {:ok, %{status: 500, body: "boom"}}

          true ->
            {:ok, %{status: 200, body: @page1}}
        end
      end

      creds = %{url: "https://netbox.example", token: "t", verify_ssl: true}

      assert {:error, {:http_status, 500}} =
               NetboxImportWorker.fetch_all_prefixes(creds, http_get: http_get)

      # No active netbox snapshot from this failed pull (get? read → NotFound)
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
               Snapshot.active_for_source(%{source: "netbox"}, actor: @system)
    end
  end

  describe "Loader + Store LPM against SQL oracle" do
    test "loader reloads promoted rows and matches SQL longest-prefix oracle" do
      rows = [
        %{
          prefix: "10.1.0.0/16",
          tags: ["site:austin", "role:corp"],
          source: "netbox",
          site: "austin"
        },
        %{
          prefix: "10.1.2.0/24",
          tags: ["role:guest-wifi"],
          source: "netbox",
          site: "austin",
          role: "guest-wifi"
        },
        %{
          prefix: "192.168.0.0/16",
          tags: ["site:lab"],
          source: "netbox",
          site: "lab"
        }
      ]

      assert :ok = NetboxImportWorker.promote_snapshot("https://nb.example", rows, %{})

      # Prefer the app Loader if running; otherwise load into Store directly
      # from the same SQL the Loader uses.
      case Process.whereis(Loader) do
        pid when is_pid(pid) ->
          assert :ok = Loader.reload("netbox")

        _ ->
          load_source_into_store!("netbox")
      end

      # Most-specific match for guest-wifi host
      chain = Store.lookup("10.1.2.3")
      assert chain != []
      most_specific = hd(chain)
      assert most_specific.prefix == "10.1.2.0/24"
      assert "role:guest-wifi" in most_specific.tags
      assert most_specific.source == "netbox"

      # Chain includes the covering /16
      prefixes = Enum.map(chain, & &1.prefix)
      assert "10.1.0.0/16" in prefixes

      # SQL oracle: same most-specific prefix + tags
      oracle = sql_lpm_oracle("10.1.2.3")
      assert oracle != []
      assert hd(oracle).prefix == most_specific.prefix

      assert MapSet.new(List.wrap(hd(oracle).tags)) ==
               MapSet.new(List.wrap(most_specific.tags))

      # Unmatched public IP
      assert Store.lookup("8.8.8.8") == []
      assert sql_lpm_oracle("8.8.8.8") == []

      # Lab /16
      lab_chain = Store.lookup("192.168.1.10")
      assert hd(lab_chain).prefix == "192.168.0.0/16"
      assert "site:lab" in hd(lab_chain).tags
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp page_results(%Ash.Page.Keyset{results: results}), do: results
  defp page_results(%Ash.Page.Offset{results: results}), do: results
  defp page_results(list) when is_list(list), do: list
  defp page_results(%{results: results}) when is_list(results), do: results
  defp page_results(other), do: List.wrap(other)

  defp load_source_into_store!(source) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT
          host(p.prefix) || '/' || masklen(p.prefix) AS prefix,
          p.tags,
          p.vrf,
          p.site,
          p.role,
          p.tenant,
          p.status,
          s.source
        FROM platform.prefix_tags p
        JOIN platform.prefix_tag_snapshots s ON s.id = p.snapshot_id
        WHERE s.is_active = TRUE AND s.source = $1
        """,
        [source]
      )

    store_rows =
      Enum.map(rows, fn [prefix, tags, vrf, site, role, tenant, status, src] ->
        %{
          prefix: prefix,
          tags: normalize_tags(tags),
          vrf: vrf,
          site: site,
          role: role,
          tenant: tenant,
          status: status,
          source: src
        }
      end)

    Store.put_rows(source, store_rows)
  end

  defp sql_lpm_oracle(ip) when is_binary(ip) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT
          host(p.prefix) || '/' || masklen(p.prefix) AS prefix,
          p.tags,
          s.source,
          masklen(p.prefix) AS mask
        FROM platform.prefix_tags p
        JOIN platform.prefix_tag_snapshots s ON s.id = p.snapshot_id
        WHERE s.is_active = TRUE
          AND ($1::text)::inet <<= p.prefix
        ORDER BY masklen(p.prefix) DESC, s.source
        """,
        [ip]
      )

    Enum.map(rows, fn [prefix, tags, source, _mask] ->
      %{prefix: prefix, tags: normalize_tags(tags), source: source}
    end)
  end

  defp normalize_tags(tags) when is_list(tags), do: Enum.map(tags, &to_string/1)
  defp normalize_tags(%{} = map), do: map |> Map.values() |> Enum.map(&to_string/1)
  defp normalize_tags(nil), do: []
  defp normalize_tags(other), do: other |> List.wrap() |> Enum.map(&to_string/1)
end
