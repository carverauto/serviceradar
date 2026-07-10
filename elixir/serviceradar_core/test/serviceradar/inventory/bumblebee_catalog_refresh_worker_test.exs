defmodule ServiceRadar.Inventory.BumblebeeCatalogRefreshWorkerTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.BumblebeeCatalogRefreshWorker
  alias ServiceRadar.Inventory.BumblebeeCatalogSnapshot
  alias ServiceRadar.Inventory.BumblebeeCatalogSource
  alias ServiceRadar.Monitoring.OcsfEvent
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    previous_config =
      Application.get_env(:serviceradar_core, BumblebeeCatalogRefreshWorker, [])

    parent = self()

    insert_job = fn changeset ->
      send(parent, {:bumblebee_reschedule, changeset})
      {:ok, %Oban.Job{}}
    end

    Application.put_env(:serviceradar_core, BumblebeeCatalogRefreshWorker,
      enabled: true,
      timeout_ms: 50,
      failure_reschedule_seconds: 900,
      insert_job: insert_job
    )

    on_exit(fn ->
      Application.put_env(:serviceradar_core, BumblebeeCatalogRefreshWorker, previous_config)
    end)

    {:ok,
     actor: SystemActor.system(:bumblebee_catalog_refresh_worker_test), insert_job: insert_job}
  end

  test "promotes a candidate snapshot with artifact metadata", %{actor: actor} do
    source = create_source!(actor, enabled: false)
    candidate = create_snapshot!(actor, source, "candidate")

    assert {:ok, promoted} =
             candidate
             |> Ash.Changeset.for_update(
               :promote,
               %{
                 entry_count: 1,
                 content_sha256: "sha-promoted",
                 object_key: "bumblebee/catalogs/promoted/catalog.json",
                 object_size_bytes: 128,
                 validation_result: %{"status" => "valid"},
                 artifact_metadata: %{"catalog_version" => "v2"}
               },
               actor: actor
             )
             |> Ash.update(actor: actor)

    assert promoted.status == "active"
    assert promoted.promoted_at
    assert promoted.content_sha256 == "sha-promoted"
    assert promoted.object_key == "bumblebee/catalogs/promoted/catalog.json"
    assert promoted.validation_result == %{"status" => "valid"}
  end

  test "successful refresh emits an OCSF catalog lifecycle event", %{
    actor: actor,
    insert_job: insert_job
  } do
    unique = System.unique_integer([:positive])

    catalog_body =
      Jason.encode!(%{
        "catalog_version" => "catalog-#{unique}",
        "schema_version" => "serviceradar.bumblebee.catalog.v1",
        "entries" => [
          %{
            "id" => "pkg-#{unique}",
            "ecosystem" => "npm",
            "package_name" => "left-pad",
            "severity" => "high",
            "affected_versions" => ["1.0.0"]
          }
        ]
      })

    Application.put_env(:serviceradar_core, BumblebeeCatalogRefreshWorker,
      enabled: true,
      timeout_ms: 50,
      failure_reschedule_seconds: 900,
      download_source: fn _url, _timeout -> {:ok, catalog_body} end,
      materialize_catalog: fn snapshot_ref, entries, metadata ->
        {:ok,
         %{
           "object_key" => "bumblebee/catalogs/#{snapshot_ref}/catalog.json",
           "content_sha256" => "sha-success-#{unique}",
           "object_size_bytes" => length(entries) + map_size(metadata),
           "entry_count" => length(entries)
         }}
      end,
      push_config: fn :bumblebee -> :ok end,
      insert_job: insert_job
    )

    source =
      create_source!(actor,
        enabled: true,
        url: "https://catalog.example.invalid/bumblebee.json?token=hidden"
      )

    assert :ok = BumblebeeCatalogRefreshWorker.perform(%Oban.Job{args: %{"force" => true}})

    assert %OcsfEvent{} =
             event =
             find_catalog_event!(actor, source.id, "bumblebee_catalog_refresh_success")

    assert event.status == "Success"
    assert event.log_name == "bumblebee.catalog.refresh"
    assert event.log_provider == "serviceradar.core"
    assert event.metadata["event_family"] == "bumblebee_catalog_refresh"
    assert event.unmapped["event_action"] == "success"
    assert event.unmapped["source_id"] == to_string(source.id)
    assert event.unmapped["source_url"] == "https://catalog.example.invalid/bumblebee.json"
    assert event.unmapped["catalog_version"] == "catalog-#{unique}"
    assert event.unmapped["entry_count"] == 1

    assert_rescheduled!("success")
  end

  test "failed refresh preserves last active snapshot", %{actor: actor} do
    source = create_source!(actor, enabled: true, url: "https://127.0.0.1:1/bumblebee.json")
    active = actor |> create_snapshot!(source, "candidate") |> promote_snapshot!(actor)

    assert :ok = BumblebeeCatalogRefreshWorker.perform(%Oban.Job{args: %{"force" => true}})

    assert {:ok, reloaded} =
             BumblebeeCatalogSnapshot
             |> Ash.Query.filter(id == ^active.id)
             |> Ash.read_one(actor: actor)

    assert reloaded.status == "active"
    assert reloaded.snapshot_ref == active.snapshot_ref
    assert reloaded.content_sha256 == active.content_sha256

    assert %OcsfEvent{} =
             event =
             find_catalog_event!(actor, source.id, "bumblebee_catalog_refresh_failure")

    assert event.status == "Failure"
    assert event.log_name == "bumblebee.catalog.refresh"
    assert event.metadata["event_family"] == "bumblebee_catalog_refresh"
    assert event.unmapped["event_action"] == "failure"
    assert event.unmapped["source_id"] == to_string(source.id)
    assert event.unmapped["reason"] =~ "connection refused"

    assert_rescheduled!("failure")
  end

  defp assert_rescheduled!(last_result) do
    assert_receive {:bumblebee_reschedule, changeset}, 1_000

    args = Ecto.Changeset.get_change(changeset, :args)
    assert args["last_result"] == last_result
    assert is_binary(args["scheduled_at"])
    assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(args["scheduled_at"])
  end

  defp create_source!(actor, opts) do
    unique = System.unique_integer([:positive])

    attrs = %{
      name: "bumblebee-test-source-#{unique}",
      url: Keyword.get(opts, :url, "https://example.invalid/bumblebee.json"),
      pinned_revision: "rev-#{unique}",
      refresh_cron: "0 0 * * *",
      enabled: Keyword.get(opts, :enabled, true),
      metadata: %{}
    }

    BumblebeeCatalogSource
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp create_snapshot!(actor, source, status) do
    unique = System.unique_integer([:positive])

    attrs = %{
      source_id: source.id,
      snapshot_ref: "bumblebee:test:#{status}:#{unique}",
      source_revision: "rev-#{unique}",
      catalog_version: "v#{unique}",
      schema_version: "serviceradar.bumblebee.catalog.v1",
      status: status,
      entry_count: 1,
      content_sha256: "sha-#{status}-#{unique}",
      object_key: "bumblebee/catalogs/#{status}/catalog.json",
      object_size_bytes: 42,
      validation_result: %{"status" => "valid"},
      artifact_metadata: %{"catalog_version" => "v#{unique}"},
      metadata: %{}
    }

    BumblebeeCatalogSnapshot
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp promote_snapshot!(snapshot, actor) do
    snapshot
    |> Ash.Changeset.for_update(
      :promote,
      %{
        entry_count: snapshot.entry_count,
        content_sha256: snapshot.content_sha256,
        object_key: snapshot.object_key,
        object_size_bytes: snapshot.object_size_bytes,
        validation_result: snapshot.validation_result,
        artifact_metadata: snapshot.artifact_metadata
      },
      actor: actor
    )
    |> Ash.update!(actor: actor)
  end

  defp find_catalog_event!(actor, source_id, status_code) do
    OcsfEvent
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.read!(actor: actor)
    |> Enum.find(fn event ->
      event.log_name == "bumblebee.catalog.refresh" and
        event.status_code == status_code and
        get_in(event.unmapped || %{}, ["source_id"]) == to_string(source_id)
    end)
  end
end
