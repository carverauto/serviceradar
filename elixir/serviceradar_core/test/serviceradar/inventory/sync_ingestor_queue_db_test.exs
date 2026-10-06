defmodule ServiceRadar.Inventory.SyncIngestorQueueDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.Processors.Metrics
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Ingestion.RuntimeMetrics
  alias ServiceRadar.Ingestion.WorkerBudget
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Inventory.SyncIngestorQueue
  alias ServiceRadar.Inventory.SyncRunLedger
  alias Serviceradar.Metric.V1.MetricBatch
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:sync_queue_regression)
    uid = "agent-#{System.unique_integer([:positive])}.example.com"

    Agent
    |> Ash.Changeset.for_create(:register_connected, %{uid: uid, name: uid}, actor: actor)
    |> Ash.create!(actor: actor)

    source =
      IntegrationSource
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "inventory-#{System.unique_integer([:positive])}",
          source_type: :armis,
          endpoint: "https://inventory.example.com",
          agent_id: uid
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, source: source}
  end

  test "a rejected middle chunk cannot activate or retire an earlier collection", %{
    source: source
  } do
    test_pid = self()

    request = fn subject, body, opts ->
      send(test_pid, {:metric_publish, self(), subject, body, opts})

      receive do
        {:puback, response} -> response
      after
        2_000 -> {:error, :timeout}
      end
    end

    publisher =
      start_supervised!({RuntimeMetrics, interval_ms: 60_000, publish_opts: [request: request]})

    previous_run = "previous-#{Ecto.UUID.generate()}"

    update = %{
      "source" => "armis",
      "source_instance" => source.id,
      "device_id" => "armis:device61",
      "ip" => "192.0.2.61",
      "mac" => "02:00:00:00:00:61",
      "hostname" => "host61.example.com",
      "is_available" => true,
      "metadata" => %{"armis_device_id" => "device61", "integration_type" => "armis"},
      "sync_meta" => meta(source.id, previous_run, 0, 1, true, population(1))
    }

    assert :ok = SyncIngestorQueue.ingest_sync_results(Jason.encode!([update]))
    assert snapshot_count(source.id, previous_run) == 1
    assert present_count(source.id) == 1

    if !Process.whereis(WorkerBudget), do: start_supervised!({WorkerBudget, pool_size: 7})
    tasks = start_supervised!({Task.Supervisor, []})
    # Occupy every general permit through the real budget owner, so the queue's
    # first accepted chunk remains in flight while another chunk is rejected.
    parent = self()
    permits = :sys.get_state(WorkerBudget).limits.general

    holders =
      for _ <- 1..permits do
        {:ok, pid} =
          Task.Supervisor.start_child(tasks, fn ->
            WorkerBudget.run(WorkerBudget, :sync, fn ->
              send(parent, {:permit_held, self()})

              receive do
                :release -> :ok
              end
            end)
          end)

        assert_receive {:permit_held, ^pid}, 1_000
        pid
      end

    queue =
      start_supervised!({SyncIngestorQueue, name: nil, task_supervisor: tasks, max_items: 1})

    previous = Application.fetch_env(:serviceradar_core, :sync_ingestor_queue_server)
    Application.put_env(:serviceradar_core, :sync_ingestor_queue_server, queue)

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:serviceradar_core, :sync_ingestor_queue_server, value)

        :error ->
          Application.delete_env(:serviceradar_core, :sync_ingestor_queue_server)
      end
    end)

    run = "incomplete-#{Ecto.UUID.generate()}"
    first = meta(source.id, run, 0, 3, false, population(0))
    middle = meta(source.id, run, 1, 3, false, population(0))
    final = meta(source.id, run, 2, 3, true, population(0))
    assert :ok = SyncIngestorQueue.enqueue(control(first))
    assert {:error, :sync_ingest_queue_full} = SyncIngestorQueue.enqueue(control(middle))
    Enum.each(holders, &send(&1, :release))
    assert_eventually(fn -> :sys.get_state(queue).bytes == 0 end)

    assert {:error, {:source_snapshot_activation_failed, :sync_run_incomplete}} =
             SyncIngestorQueue.ingest_sync_results(control(final))

    assert snapshot_count(source.id, run) == 0
    assert snapshot_count(source.id, previous_run) == 1
    assert present_count(source.id) == 1

    # A separate complete run must recover normally; the failure is run-scoped.
    recovered = "recovered-#{Ecto.UUID.generate()}"

    assert :ok =
             SyncIngestorQueue.ingest_sync_results(
               control(meta(source.id, recovered, 0, 1, true, population(0)))
             )

    assert snapshot_count(source.id, recovered) == 1
    assert present_count(source.id) == 0

    send(publisher, :publish)

    assert_receive {:metric_publish, ^publisher, "metrics.ingestion_lanes", frame, _opts},
                   1_000

    send(publisher, {:puback, {:ok, %{body: Jason.encode!(%{stream: "METRICS", seq: 1})}}})

    incomplete =
      frame
      |> MetricBatch.decode()
      |> Map.fetch!(:metrics)
      |> Enum.find(&(&1.name == "result_ingestion_events_incomplete_run"))

    assert %{points: [%{value: 1.0}], temporality: :METRIC_TEMPORALITY_DELTA} =
             incomplete

    incomplete_row =
      frame
      |> decode_ingestion_rows!()
      |> Enum.find(&(&1.metric_name == "result_ingestion_events_incomplete_run"))

    assert incomplete_row.value == 1.0
    assert incomplete_row.is_delta == true
    assert incomplete_row.metadata["temporality"] == "delta"
  end

  test "receipt replay does not clear rejection and a missing index fails closed", %{
    source: source
  } do
    run = "receipt-#{Ecto.UUID.generate()}"
    first = meta(source.id, run, 0, 0, false, population(0))
    final = meta(source.id, run, 2, 3, true, population(0))
    middle = meta(source.id, run, 1, 3, false, population(0))
    assert :ok = SyncRunLedger.committed([first, final])
    assert {:error, :sync_run_incomplete} = SyncRunLedger.complete(final)
    assert :ok = SyncRunLedger.reject(middle)
    assert :ok = SyncRunLedger.committed([middle, first, final])
    assert {:error, :sync_run_incomplete} = SyncRunLedger.complete(final)

    assert %{rows: [[true, [0, 1, 2], 3]]} =
             Repo.query!(
               "SELECT incomplete, received_chunks, total_chunks FROM platform.sync_ingest_runs WHERE sync_service_id = $1 AND sync_run_id = $2",
               [Ecto.UUID.dump!(source.id), run]
             )
  end

  defp meta(source, run, index, total, final, population) do
    %{
      sync_service_id: source,
      sync_run_id: run,
      chunk_index: index,
      total_chunks: total,
      is_final: final,
      population: population
    }
  end

  defp population(count) do
    %{
      raw_rows: count,
      excluded_rows: 0,
      invalid_rows: 0,
      valid_occurrences: count,
      distinct_source_ids: count,
      duplicate_occurrences: 0,
      conflicting_duplicate_ids: 0
    }
  end

  defp decode_ingestion_rows!(body) do
    Metrics.parse_message(%{data: body, metadata: %{subject: "metrics.ingestion_lanes"}})
  end

  defp control(meta),
    do: Jason.encode!([%{"_sync_control" => "collection_final", "sync_meta" => meta}])

  defp snapshot_count(source, run) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.device_source_snapshots WHERE source_instance = $1 AND collection_id = $2",
        [source, run]
      )

    count
  end

  defp present_count(source) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.device_source_observations WHERE source_instance = $1 AND present",
        [source]
      )

    count
  end

  defp assert_eventually(fun, attempts \\ 80)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(25)
          assert_eventually(fun, attempts - 1)
        )
  end
end
