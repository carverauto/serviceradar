defmodule ServiceRadar.Inventory.EndpointInventoryRetentionTest do
  use ServiceRadar.DataCase, async: true

  import Ecto.Query

  alias ServiceRadar.Inventory.EndpointInventoryRetention
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    Repo.delete_all("endpoint_inventory_packages", prefix: "platform")
    Repo.delete_all("endpoint_inventory_artifacts", prefix: "platform")
    Repo.delete_all("endpoint_inventory_scans", prefix: "platform")
    Repo.delete_all("endpoint_inventory_artifact_contents", prefix: "platform")

    :ok
  end

  test "deletes old non-current scans and SBOM objects while preserving current inventory" do
    unique = System.unique_integer([:positive])
    agent_id = "endpoint-retention-agent-#{unique}"
    old_scan_ref = insert_scan!(agent_id, "old-#{unique}", false, -45)
    current_scan_ref = insert_scan!(agent_id, "current-#{unique}", true, -45)
    failed_scan_ref = insert_scan!(agent_id, "blocked-#{unique}", false, -45)
    fresh_scan_ref = insert_scan!(agent_id, "fresh-#{unique}", false, -5)

    old_key = "endpoint-inventory/#{agent_id}/old/sbom.cdx.json"
    failed_key = "endpoint-inventory/#{agent_id}/blocked/sbom.cdx.json"

    insert_artifact!(old_scan_ref, agent_id, old_key)
    insert_package!(old_scan_ref, agent_id, "old-nginx", false)

    insert_artifact!(
      current_scan_ref,
      agent_id,
      "endpoint-inventory/#{agent_id}/current/sbom.cdx.json"
    )

    insert_package!(current_scan_ref, agent_id, "current-nginx", true)
    insert_artifact!(failed_scan_ref, agent_id, failed_key)
    insert_package!(failed_scan_ref, agent_id, "blocked-nginx", false)
    insert_package!(fresh_scan_ref, agent_id, "fresh-nginx", false)

    test = self()

    delete_object = fn
      ^old_key, opts ->
        send(test, {:delete_object, old_key, opts})
        {:ok, true}

      ^failed_key, opts ->
        send(test, {:delete_object, failed_key, opts})
        {:error, :datasvc_unavailable}
    end

    assert {:ok, summary} =
             EndpointInventoryRetention.prune(
               retention_days: 30,
               batch_size: 10,
               timeout: 123,
               delete_object: delete_object
             )

    assert summary.scanned == 2
    assert summary.eligible_scans == 1
    assert summary.deleted_scans == 1
    assert summary.deleted_objects == 1
    assert summary.failed_objects == 1
    assert_receive {:delete_object, ^old_key, [timeout: 123]}
    assert_receive {:delete_object, ^failed_key, [timeout: 123]}

    refute scan_exists?(old_scan_ref)
    refute package_exists?("old-nginx")
    refute artifact_exists?(old_key)

    assert scan_exists?(current_scan_ref)
    assert package_exists?("current-nginx")
    assert scan_exists?(failed_scan_ref)
    assert package_exists?("blocked-nginx")
    assert artifact_exists?(failed_key)
    assert scan_exists?(fresh_scan_ref)
    assert package_exists?("fresh-nginx")
  end

  test "does not delete content-addressed object while another scan references it" do
    unique = System.unique_integer([:positive])
    agent_id = "endpoint-retention-shared-agent-#{unique}"
    old_scan_ref = insert_scan!(agent_id, "shared-old-#{unique}", false, -45)
    current_scan_ref = insert_scan!(agent_id, "shared-current-#{unique}", true, -45)
    artifact_hash = String.duplicate("c", 64)
    object_key = "endpoint-inventory/by-hash/#{artifact_hash}.cdx.json"
    content_ref = insert_artifact_content!(artifact_hash, object_key)

    insert_artifact!(old_scan_ref, agent_id, object_key,
      artifact_hash: artifact_hash,
      artifact_content_ref: content_ref
    )

    insert_artifact!(current_scan_ref, agent_id, object_key,
      artifact_hash: artifact_hash,
      artifact_content_ref: content_ref
    )

    test = self()

    delete_object = fn deleted_object_key, _opts ->
      send(test, {:delete_object, deleted_object_key})
      {:ok, true}
    end

    assert {:ok, summary} =
             EndpointInventoryRetention.prune(
               retention_days: 30,
               batch_size: 10,
               delete_object: delete_object
             )

    assert summary.scanned == 1
    assert summary.deleted_scans == 1
    assert summary.deleted_objects == 0
    refute_receive {:delete_object, _}, 50

    refute scan_exists?(old_scan_ref)
    assert scan_exists?(current_scan_ref)
    assert artifact_exists?(object_key)
    assert artifact_content_exists?(artifact_hash)
  end

  defp insert_scan!(agent_id, scan_id, current?, age_days) do
    timestamp = DateTime.add(DateTime.utc_now(), age_days * 86_400, :second)

    {1, [%{id: id}]} =
      Repo.insert_all(
        "endpoint_inventory_scans",
        [
          %{
            agent_id: agent_id,
            scan_id: scan_id,
            state: "scanned",
            coverage_state: "complete",
            current: current?,
            last_scan_at: timestamp,
            ingested_at: timestamp,
            inserted_at: timestamp,
            updated_at: timestamp
          }
        ],
        prefix: "platform",
        returning: [:id]
      )

    id
  end

  defp insert_artifact!(scan_ref, agent_id, object_key, opts \\ []) do
    now = DateTime.utc_now()
    artifact_hash = Keyword.get(opts, :artifact_hash)
    artifact_content_ref = Keyword.get(opts, :artifact_content_ref)

    Repo.insert_all(
      "endpoint_inventory_artifacts",
      [
        %{
          scan_ref: scan_ref,
          artifact_content_ref: artifact_content_ref,
          agent_id: agent_id,
          artifact_hash: artifact_hash,
          object_key: object_key,
          sha256: String.duplicate("a", 64),
          size_bytes: 12,
          reused_content: Keyword.get(opts, :reused_content, false),
          uploaded_at: now,
          inserted_at: now
        }
      ],
      prefix: "platform"
    )
  end

  defp insert_artifact_content!(artifact_hash, object_key) do
    now = DateTime.utc_now()

    {1, [%{id: id}]} =
      Repo.insert_all(
        "endpoint_inventory_artifact_contents",
        [
          %{
            artifact_hash: artifact_hash,
            object_key: object_key,
            sha256: String.duplicate("a", 64),
            size_bytes: 12,
            first_uploaded_at: now,
            last_referenced_at: now,
            reference_count: 2,
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: "platform",
        returning: [:id]
      )

    id
  end

  defp insert_package!(scan_ref, agent_id, name, current?) do
    now = DateTime.utc_now()
    endpoint_package_ref = Ecto.UUID.dump!(Ecto.UUID.generate())
    purl = "pkg:deb/#{name}"

    Repo.insert_all(
      "endpoint_packages",
      [
        %{
          id: endpoint_package_ref,
          coordinate_key: "purl:#{purl}",
          purl_canonical: purl,
          package_manager: "dpkg",
          name: name,
          source_scope: "host",
          metadata: %{},
          inserted_at: now,
          updated_at: now
        }
      ],
      prefix: "platform"
    )

    Repo.insert_all(
      "endpoint_inventory_packages",
      [
        %{
          scan_ref: scan_ref,
          endpoint_package_ref: endpoint_package_ref,
          agent_id: agent_id,
          name: name,
          package_manager: "dpkg",
          purl_canonical: purl,
          current: current?,
          inserted_at: now,
          updated_at: now
        }
      ],
      prefix: "platform"
    )
  end

  defp scan_exists?(scan_ref) do
    Repo.exists?(
      from(s in "endpoint_inventory_scans", where: s.id == ^scan_ref),
      prefix: "platform"
    )
  end

  defp artifact_exists?(object_key) do
    Repo.exists?(
      from(a in "endpoint_inventory_artifacts", where: a.object_key == ^object_key),
      prefix: "platform"
    )
  end

  defp artifact_content_exists?(artifact_hash) do
    Repo.exists?(
      from(c in "endpoint_inventory_artifact_contents", where: c.artifact_hash == ^artifact_hash),
      prefix: "platform"
    )
  end

  defp package_exists?(name) do
    Repo.exists?(
      from(p in "endpoint_inventory_packages", where: p.name == ^name),
      prefix: "platform"
    )
  end
end
