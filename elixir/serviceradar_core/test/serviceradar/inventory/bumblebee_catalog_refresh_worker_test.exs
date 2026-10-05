defmodule ServiceRadar.Inventory.BumblebeeCatalogRefreshWorkerTest do
  use ServiceRadar.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.BumblebeeCatalogEntry
  alias ServiceRadar.Inventory.BumblebeeCatalogRefreshWorker
  alias ServiceRadar.Inventory.BumblebeeCatalogSnapshot
  alias ServiceRadar.Inventory.BumblebeeCatalogSource
  alias ServiceRadar.Monitoring.OcsfEvent
  alias ServiceRadar.Repo
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

  # The pending job is a successor, as in production: successors carry "scheduled_at" and
  # "last_result", so a guard that only recognises `%{}` args would insert a second chain.
  test "ensure_scheduled/0 reports a pending refresh job instead of inserting another" do
    delete_refresh_jobs()
    pending = insert_scheduled_refresh_job!(3_600, successor_args("success"))

    assert {:ok, :already_scheduled} = BumblebeeCatalogRefreshWorker.ensure_scheduled()
    assert refresh_job_states() == %{pending.id => "scheduled"}
  end

  # A guard that misses the pending job inserts another self-rescheduling chain on every
  # coordinator start, and those chains never stop on their own; ensure_scheduled/0 must trim
  # them back to a single pending job. The chain mixes the first `%{}` job with successors, and
  # a forced refresh is a one-off that is due first yet is neither counted nor cancelled.
  test "ensure_scheduled/0 cancels duplicate chains down to the earliest-due job" do
    delete_refresh_jobs()
    executing = insert_executing_refresh_job!()
    forced = insert_scheduled_refresh_job!(60, %{"force" => true})
    earliest = insert_scheduled_refresh_job!(600, successor_args("success"))
    later = insert_scheduled_refresh_job!(3_600, %{})
    latest = insert_scheduled_refresh_job!(7_200, successor_args("failure"))

    expected = %{
      executing.id => "executing",
      forced.id => "scheduled",
      earliest.id => "scheduled",
      later.id => "cancelled",
      latest.id => "cancelled"
    }

    assert {:ok, :already_scheduled} = BumblebeeCatalogRefreshWorker.ensure_scheduled()
    assert refresh_job_states() == expected

    # A repeated call, as from another node, cancels nothing further.
    assert {:ok, :already_scheduled} = BumblebeeCatalogRefreshWorker.ensure_scheduled()
    assert refresh_job_states() == expected
  end

  test "catalog entries are written in chunked bulk upserts scaling with chunks, not entries", %{
    actor: actor,
    insert_job: insert_job
  } do
    unique = System.unique_integer([:positive])
    entry_count = 600

    entries =
      for i <- 1..entry_count do
        %{
          "id" => "pkg-scale-#{unique}-#{i}",
          "ecosystem" => "npm",
          "package_name" => "package-#{i}",
          "severity" => "medium",
          "affected_versions" => ["1.0.0"]
        }
      end

    catalog_body =
      Jason.encode!(%{
        "catalog_version" => "catalog-scale-#{unique}",
        "schema_version" => "serviceradar.bumblebee.catalog.v1",
        "entries" => entries
      })

    # Test 1: Single chunk of 1000 holds all 600 entries -> exactly 1 batched INSERT.
    Application.put_env(:serviceradar_core, BumblebeeCatalogRefreshWorker,
      enabled: true,
      timeout_ms: 50,
      upsert_batch_size: 1_000,
      failure_reschedule_seconds: 900,
      download_source: fn _url, _timeout -> {:ok, catalog_body} end,
      materialize_catalog: fn snapshot_ref, entries, metadata ->
        {:ok,
         %{
           "object_key" => "bumblebee/catalogs/#{snapshot_ref}/catalog.json",
           "content_sha256" => "sha-scale-1-#{unique}",
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
        url: "https://catalog.example.invalid/scale-1.json"
      )

    {res1, inserts1} =
      counting_catalog_entry_inserts(fn ->
        BumblebeeCatalogRefreshWorker.perform(%Oban.Job{args: %{"force" => true}})
      end)

    assert res1 == :ok
    assert inserts1 in 1..2, "expected a single batched INSERT for 600 entries, got #{inserts1}"

    active_snapshot =
      BumblebeeCatalogSnapshot
      |> Ash.Query.filter(source_id == ^source.id and status == "active")
      |> Ash.read_one!(actor: actor)

    stored_entries =
      BumblebeeCatalogEntry
      |> Ash.Query.filter(snapshot_id == ^active_snapshot.id)
      |> Ash.read!(actor: actor)

    assert length(stored_entries) == entry_count

    # Test 2: Chunk size 250 -> 600 entries produces ceil(600/250) = 3 batched INSERTs.
    unique2 = System.unique_integer([:positive])

    catalog_body2 =
      Jason.encode!(%{
        "catalog_version" => "catalog-scale-#{unique2}",
        "schema_version" => "serviceradar.bumblebee.catalog.v1",
        "entries" => entries
      })

    Application.put_env(:serviceradar_core, BumblebeeCatalogRefreshWorker,
      enabled: true,
      timeout_ms: 50,
      upsert_batch_size: 250,
      failure_reschedule_seconds: 900,
      download_source: fn _url, _timeout -> {:ok, catalog_body2} end,
      materialize_catalog: fn snapshot_ref, entries, metadata ->
        {:ok,
         %{
           "object_key" => "bumblebee/catalogs/#{snapshot_ref}/catalog.json",
           "content_sha256" => "sha-scale-2-#{unique2}",
           "object_size_bytes" => length(entries) + map_size(metadata),
           "entry_count" => length(entries)
         }}
      end,
      push_config: fn :bumblebee -> :ok end,
      insert_job: insert_job
    )

    source2 =
      create_source!(actor,
        enabled: true,
        url: "https://catalog.example.invalid/scale-2.json"
      )

    {res2, inserts2} =
      counting_catalog_entry_inserts(fn ->
        BumblebeeCatalogRefreshWorker.perform(%Oban.Job{args: %{"force" => true}})
      end)

    assert res2 == :ok

    assert inserts2 in 2..4,
           "expected ~3 batched INSERTs for 600 entries in batches of 250, got #{inserts2}"

    active_snapshot2 =
      BumblebeeCatalogSnapshot
      |> Ash.Query.filter(source_id == ^source2.id and status == "active")
      |> Ash.read_one!(actor: actor)

    stored_entries2 =
      BumblebeeCatalogEntry
      |> Ash.Query.filter(snapshot_id == ^active_snapshot2.id)
      |> Ash.read!(actor: actor)

    assert length(stored_entries2) == entry_count
  end

  test "duplicate entries for the same catalog_id within a batch are deduplicated", %{
    actor: actor,
    insert_job: insert_job
  } do
    unique = System.unique_integer([:positive])

    entries = [
      %{
        "id" => "pkg-dup-#{unique}",
        "ecosystem" => "npm",
        "package_name" => "dup-package",
        "severity" => "low",
        "affected_versions" => ["1.0.0"]
      },
      %{
        "id" => "pkg-dup-#{unique}",
        "ecosystem" => "npm",
        "package_name" => "dup-package",
        "severity" => "critical",
        "affected_versions" => ["2.0.0"]
      }
    ]

    catalog_body =
      Jason.encode!(%{
        "catalog_version" => "catalog-dup-#{unique}",
        "schema_version" => "serviceradar.bumblebee.catalog.v1",
        "entries" => entries
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
           "content_sha256" => "sha-dup-#{unique}",
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
        url: "https://catalog.example.invalid/dup.json"
      )

    assert :ok = BumblebeeCatalogRefreshWorker.perform(%Oban.Job{args: %{"force" => true}})

    active_snapshot =
      BumblebeeCatalogSnapshot
      |> Ash.Query.filter(source_id == ^source.id and status == "active")
      |> Ash.read_one!(actor: actor)

    stored =
      BumblebeeCatalogEntry
      |> Ash.Query.filter(snapshot_id == ^active_snapshot.id)
      |> Ash.read!(actor: actor)

    assert length(stored) == 1
  end

  defp insert_scheduled_refresh_job!(schedule_in, args) do
    args
    |> BumblebeeCatalogRefreshWorker.new(schedule_in: schedule_in)
    |> Repo.insert!()
  end

  defp successor_args(last_result) do
    %{"scheduled_at" => DateTime.to_iso8601(DateTime.utc_now()), "last_result" => last_result}
  end

  defp insert_executing_refresh_job! do
    %{}
    |> BumblebeeCatalogRefreshWorker.new()
    |> Ecto.Changeset.change(state: "executing", attempt: 1, attempted_at: DateTime.utc_now())
    |> Repo.insert!()
  end

  defp refresh_job_states do
    worker = Oban.Worker.to_string(BumblebeeCatalogRefreshWorker)
    query = from(job in Oban.Job, where: job.worker == ^worker, select: {job.id, job.state})

    query |> Repo.all() |> Map.new()
  end

  defp delete_refresh_jobs do
    worker = Oban.Worker.to_string(BumblebeeCatalogRefreshWorker)
    Repo.delete_all(from(job in Oban.Job, where: job.worker == ^worker))
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

  defp counting_catalog_entry_inserts(fun) do
    handler_id = "bumblebee-catalog-entry-insert-count-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:service_radar, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if self() == test_pid and
               String.starts_with?(query, ~s(INSERT INTO "platform"."bumblebee_catalog_entries")) do
            send(test_pid, :catalog_entry_insert)
          end
        end,
        nil
      )

    try do
      result = fun.()
      inserts = drain_inserts()
      {result, inserts}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_inserts(acc \\ 0) do
    receive do
      :catalog_entry_insert -> drain_inserts(acc + 1)
    after
      0 -> acc
    end
  end
end
