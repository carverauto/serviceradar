defmodule ServiceRadar.Inventory.EndpointInventoryRetentionTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ServiceRadar.Inventory.EndpointInventoryRetention
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
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

  defp insert_artifact!(scan_ref, agent_id, object_key) do
    now = DateTime.utc_now()

    Repo.insert_all(
      "endpoint_inventory_artifacts",
      [
        %{
          scan_ref: scan_ref,
          agent_id: agent_id,
          object_key: object_key,
          sha256: String.duplicate("a", 64),
          size_bytes: 12,
          uploaded_at: now,
          inserted_at: now
        }
      ],
      prefix: "platform"
    )
  end

  defp insert_package!(scan_ref, agent_id, name, current?) do
    now = DateTime.utc_now()

    Repo.insert_all(
      "endpoint_inventory_packages",
      [
        %{
          scan_ref: scan_ref,
          agent_id: agent_id,
          name: name,
          package_manager: "dpkg",
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

  defp package_exists?(name) do
    Repo.exists?(
      from(p in "endpoint_inventory_packages", where: p.name == ^name),
      prefix: "platform"
    )
  end
end
