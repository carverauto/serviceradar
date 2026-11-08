defmodule ServiceRadar.Inventory.SyncIngestorQueueDbTest do
  use ServiceRadar.DataCase, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.Projectors.DiscoveryCommon
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

    if !Process.whereis(WorkerBudget), do: start_supervised!({WorkerBudget, pool_size: 8})
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

    # Receipts are written inside a transaction; Ash drops (and logs) any notification the
    # ledger does not collect and send after the commit.
    log =
      capture_log(fn ->
        assert :ok = SyncRunLedger.committed([first, final])
        assert {:error, :sync_run_incomplete} = SyncRunLedger.complete(final)
        assert :ok = SyncRunLedger.reject(middle)
        assert :ok = SyncRunLedger.committed([middle, first, final])
        assert {:error, :sync_run_incomplete} = SyncRunLedger.complete(final)
      end)

    refute log =~ "notifications in action ServiceRadar.Inventory.SyncIngestRun."

    assert %{rows: [[true, [0, 1, 2], 3]]} =
             Repo.query!(
               "SELECT incomplete, received_chunks, total_chunks FROM platform.sync_ingest_runs WHERE sync_service_id = $1 AND sync_run_id = $2",
               [Ecto.UUID.dump!(source.id), run]
             )
  end

  test "an unattributable rejected chunk cannot activate a partial snapshot and persists available incompleteness outside queue callbacks",
       %{source: source} do
    previous_run = "previous-#{Ecto.UUID.generate()}"

    assert :ok =
             SyncIngestorQueue.ingest_sync_results(
               Jason.encode!([
                 device_update(source.id, previous_run, 71, 0, 1, true, population(1))
               ])
             )

    assert snapshot_count(source.id, previous_run) == 1
    assert present_count(source.id) == 1

    if !Process.whereis(WorkerBudget), do: start_supervised!({WorkerBudget, pool_size: 8})
    tasks = start_supervised!({Task.Supervisor, []})
    holders = hold_general_permits(tasks)

    queue =
      start_supervised!({SyncIngestorQueue, name: nil, task_supervisor: tasks, max_items: 1})

    previous = Application.fetch_env(:serviceradar_core, :sync_ingestor_queue_server)
    Application.put_env(:serviceradar_core, :sync_ingestor_queue_server, queue)

    handler_id = {__MODULE__, :repo_query_owner, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:service_radar, :repo, :query], [:serviceradar, :repo, :query]],
        &__MODULE__.forward_repo_query/4,
        self()
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      restore_queue_server(previous)
    end)

    # Case A: the rejected chunk carries run identity (sync_service_id + sync_run_id)
    # but an unattributable chunk_index (nil). Available incompleteness is persisted
    # by the caller process outside SyncIngestorQueue callbacks.
    run_missing_index = "unattributable-index-#{Ecto.UUID.generate()}"
    first_missing_index = meta(source.id, run_missing_index, 0, 2, false, population(0))
    rejected_missing_index = meta(source.id, run_missing_index, nil, 2, false, population(0))
    final_missing_index = meta(source.id, run_missing_index, 1, 2, true, population(0))

    assert :ok = SyncIngestorQueue.enqueue(control(first_missing_index))
    _ = drain_repo_query_pids()

    assert {:error, :sync_ingest_queue_full} =
             SyncIngestorQueue.enqueue(control(rejected_missing_index))

    rejection_query_pids = drain_repo_query_pids()
    assert self() in rejection_query_pids
    refute queue in rejection_query_pids

    assert %{rows: [[true, [], 2]]} =
             Repo.query!(
               "SELECT incomplete, received_chunks, total_chunks FROM platform.sync_ingest_runs WHERE sync_service_id = $1 AND sync_run_id = $2",
               [Ecto.UUID.dump!(source.id), run_missing_index]
             )

    _ = drain_repo_query_pids()

    # Case B: a raw rejected middle chunk has no attributable sync_run_id at all
    # (malformed JSON or missing sync_meta). Neither the queue nor the caller
    # issues a Repo query on rejection, and the affected 3-chunk run still fails
    # closed when its remaining chunks arrive.
    assert {:error, :sync_ingest_queue_full} = SyncIngestorQueue.enqueue("{unattributable")
    assert {:error, :sync_ingest_queue_full} = SyncIngestorQueue.enqueue(control(%{}))
    assert Enum.filter(drain_repo_query_pids(), &(&1 in [self(), queue])) == []

    Enum.each(holders, &send(&1, :release))
    assert_eventually(fn -> :sys.get_state(queue).bytes == 0 end)
    refute queue in drain_repo_query_pids()

    assert {:error, {:source_snapshot_activation_failed, :sync_run_incomplete}} =
             SyncIngestorQueue.ingest_sync_results(control(final_missing_index))

    assert snapshot_count(source.id, run_missing_index) == 0

    run_unattributable = "unattributable-raw-#{Ecto.UUID.generate()}"
    first_unattributable = meta(source.id, run_unattributable, 0, 3, false, population(0))
    final_unattributable = meta(source.id, run_unattributable, 2, 3, true, population(0))

    assert :ok = SyncIngestorQueue.enqueue(control(first_unattributable))
    assert_eventually(fn -> :sys.get_state(queue).bytes == 0 end)

    assert {:error, {:source_snapshot_activation_failed, :sync_run_incomplete}} =
             SyncIngestorQueue.ingest_sync_results(control(final_unattributable))

    assert snapshot_count(source.id, run_unattributable) == 0
    assert snapshot_count(source.id, previous_run) == 1
    assert present_count(source.id) == 1
  end

  test "preserves ledger incompleteness and the population guard across SyncIngestorQueue restart and replay",
       %{source: source} do
    previous_run = "previous-#{Ecto.UUID.generate()}"

    assert :ok =
             SyncIngestorQueue.ingest_sync_results(
               Jason.encode!([
                 device_update(source.id, previous_run, 81, 0, 1, true, population(2)),
                 device_update(source.id, previous_run, 82, 0, 1, true, population(2))
               ])
             )

    assert snapshot_count(source.id, previous_run) == 1
    assert present_count(source.id) == 2

    if !Process.whereis(WorkerBudget), do: start_supervised!({WorkerBudget, pool_size: 8})
    tasks = start_supervised!({Task.Supervisor, []})
    holders = hold_general_permits(tasks)

    queue_1 =
      start_supervised!(
        Supervisor.child_spec(
          {SyncIngestorQueue, name: nil, task_supervisor: tasks, max_items: 1},
          id: :restartable_sync_queue
        )
      )

    previous = Application.fetch_env(:serviceradar_core, :sync_ingestor_queue_server)
    Application.put_env(:serviceradar_core, :sync_ingestor_queue_server, queue_1)
    on_exit(fn -> restore_queue_server(previous) end)

    # 1. A run with a rejected chunk before queue restart remains incomplete
    # even when all chunks are replayed through the restarted queue process.
    rejected_run = "restart-rejected-#{Ecto.UUID.generate()}"
    rejected_chunk_0 = device_update(source.id, rejected_run, 81, 0, 2, false, nil)
    rejected_chunk_1 = meta(source.id, rejected_run, 1, 2, true, population(1))

    assert :ok = SyncIngestorQueue.enqueue(Jason.encode!([rejected_chunk_0]))

    assert {:error, :sync_ingest_queue_full} =
             SyncIngestorQueue.enqueue(control(rejected_chunk_1))

    Enum.each(holders, &send(&1, :release))
    assert_eventually(fn -> :sys.get_state(queue_1).bytes == 0 end)

    :ok = stop_supervised!(:restartable_sync_queue)

    queue_2 =
      start_supervised!(
        Supervisor.child_spec(
          {SyncIngestorQueue, name: nil, task_supervisor: tasks, max_items: 4},
          id: :restartable_sync_queue
        )
      )

    assert queue_2 != queue_1
    Application.put_env(:serviceradar_core, :sync_ingestor_queue_server, queue_2)

    assert :ok = SyncIngestorQueue.enqueue(Jason.encode!([rejected_chunk_0]))
    assert_eventually(fn -> :sys.get_state(queue_2).bytes == 0 end)

    assert {:error, {:source_snapshot_activation_failed, :sync_run_incomplete}} =
             SyncIngestorQueue.ingest_sync_results(control(rejected_chunk_1))

    assert %{rows: [[true, [0, 1], 2]]} =
             Repo.query!(
               "SELECT incomplete, received_chunks, total_chunks FROM platform.sync_ingest_runs WHERE sync_service_id = $1 AND sync_run_id = $2",
               [Ecto.UUID.dump!(source.id), rejected_run]
             )

    assert snapshot_count(source.id, rejected_run) == 0
    assert present_count(source.id) == 2

    # 2. A run whose chunks all commit across a queue restart and chunk replay
    # (received_chunks == [0, 1], incomplete == false) still enforces the
    # ArmisSourceSnapshot population guard when distinct_source_ids does not match.
    mismatch_run = "restart-population-guard-#{Ecto.UUID.generate()}"
    mismatch_chunk_0 = device_update(source.id, mismatch_run, 81, 0, 2, false, nil)
    mismatch_chunk_1 = meta(source.id, mismatch_run, 1, 2, true, population(2))

    assert :ok = SyncIngestorQueue.enqueue(Jason.encode!([mismatch_chunk_0]))
    assert_eventually(fn -> :sys.get_state(queue_2).bytes == 0 end)

    :ok = stop_supervised!(:restartable_sync_queue)

    queue_3 =
      start_supervised!(
        Supervisor.child_spec(
          {SyncIngestorQueue, name: nil, task_supervisor: tasks, max_items: 4},
          id: :restartable_sync_queue
        )
      )

    assert queue_3 != queue_2
    Application.put_env(:serviceradar_core, :sync_ingestor_queue_server, queue_3)

    assert :ok = SyncIngestorQueue.enqueue(Jason.encode!([mismatch_chunk_0]))
    assert :ok = SyncIngestorQueue.enqueue(control(mismatch_chunk_1))
    assert_eventually(fn -> :sys.get_state(queue_3).bytes == 0 end)

    assert %{rows: [[false, [0, 1], 2]]} =
             Repo.query!(
               "SELECT incomplete, received_chunks, total_chunks FROM platform.sync_ingest_runs WHERE sync_service_id = $1 AND sync_run_id = $2",
               [Ecto.UUID.dump!(source.id), mismatch_run]
             )

    assert :ok = SyncRunLedger.complete(mismatch_chunk_1)

    assert {:error, {:source_snapshot_activation_failed, {:source_membership_mismatch, 2, 1}}} =
             SyncIngestorQueue.ingest_sync_results(control(mismatch_chunk_1))

    assert snapshot_count(source.id, mismatch_run) == 0
    assert snapshot_count(source.id, previous_run) == 1
    assert present_count(source.id) == 2

    # 3. A complete 2-chunk run across the restarted queue that satisfies the
    # population guard activates its snapshot normally.
    complete_run = "restart-complete-#{Ecto.UUID.generate()}"

    assert :ok =
             SyncIngestorQueue.enqueue(
               Jason.encode!([device_update(source.id, complete_run, 81, 0, 2, false, nil)])
             )

    assert :ok =
             SyncIngestorQueue.enqueue(
               Jason.encode!([
                 device_update(source.id, complete_run, 82, 1, 2, true, population(2))
               ])
             )

    assert_eventually(fn -> snapshot_count(source.id, complete_run) == 1 end)
    assert present_count(source.id) == 2
  end

  test "a redelivered chunk after a transient refusal leaves its run activatable", %{
    source: source
  } do
    if !Process.whereis(WorkerBudget), do: start_supervised!({WorkerBudget, pool_size: 8})
    tasks = start_supervised!({Task.Supervisor, []})
    queue = start_supervised!({SyncIngestorQueue, name: nil, task_supervisor: tasks})

    previous = Application.fetch_env(:serviceradar_core, :sync_ingestor_queue_server)
    on_exit(fn -> restore_queue_server(previous) end)

    run = "redelivered-#{Ecto.UUID.generate()}"
    chunk_0 = Jason.encode!([device_update(source.id, run, 91, 0, 2, false, nil)])
    final = Jason.encode!([device_update(source.id, run, 92, 1, 2, true, population(2))])

    # The first delivery finds no queue anywhere; the edge record is redelivered.
    Application.put_env(:serviceradar_core, :sync_ingestor_queue_server, :no_sync_ingest_queue)

    assert {:error, :sync_ingest_queue_unavailable} =
             DiscoveryCommon.schedule_sync_ingestion(chunk_0)

    Application.put_env(:serviceradar_core, :sync_ingestor_queue_server, queue)
    assert :ok = DiscoveryCommon.schedule_sync_ingestion(chunk_0)
    assert_eventually(fn -> :sys.get_state(queue).bytes == 0 end)
    assert :ok = DiscoveryCommon.schedule_sync_ingestion(final)

    assert_eventually(fn -> snapshot_count(source.id, run) == 1 end)

    assert %{rows: [[false, [0, 1], 2]]} =
             Repo.query!(
               "SELECT incomplete, received_chunks, total_chunks FROM platform.sync_ingest_runs WHERE sync_service_id = $1 AND sync_run_id = $2",
               [Ecto.UUID.dump!(source.id), run]
             )
  end

  test "an aborted partial run with a failure control marker rejects the run and marks IntegrationSource failed",
       %{source: source} do
    actor = SystemActor.system(:sync_queue_regression)
    previous_run = "previous-#{Ecto.UUID.generate()}"

    assert :ok =
             SyncIngestorQueue.ingest_sync_results(
               Jason.encode!([
                 device_update(source.id, previous_run, 101, 0, 1, true, population(1))
               ])
             )

    assert snapshot_count(source.id, previous_run) == 1
    {:ok, synced_source} = IntegrationSource.get_by_id(source.id, actor: actor)
    assert synced_source.sync_status == :success

    aborted_run = "aborted-#{Ecto.UUID.generate()}"

    # Chunk 0 streamed 1 device before the upstream endpoint stalled on page 1.
    assert :ok =
             SyncIngestorQueue.ingest_sync_results(
               Jason.encode!([
                 device_update(source.id, aborted_run, 102, 0, 0, false, nil)
               ])
             )

    failure_control =
      Jason.encode!([
        %{
          "_sync_control" =>
            "collection_timeout:partial armis sync after streaming 1 devices: context deadline exceeded",
          "timestamp" => "2026-09-01T08:00:00Z",
          "sync_meta" => %{
            "sync_service_id" => source.id,
            "sync_run_id" => aborted_run,
            "chunk_index" => 1,
            "total_chunks" => 0,
            "total_devices" => 1,
            "is_final" => false
          }
        }
      ])

    assert {:error,
            {:timeout, "partial armis sync after streaming 1 devices: context deadline exceeded"}} =
             SyncIngestorQueue.ingest_sync_results(failure_control)

    assert %{rows: [[true, [0], 0]]} =
             Repo.query!(
               "SELECT incomplete, received_chunks, total_chunks FROM platform.sync_ingest_runs WHERE sync_service_id = $1 AND sync_run_id = $2",
               [Ecto.UUID.dump!(source.id), aborted_run]
             )

    assert snapshot_count(source.id, aborted_run) == 0
    assert snapshot_count(source.id, previous_run) == 1

    {:ok, failed_source} = IntegrationSource.get_by_id(source.id, actor: actor)
    assert failed_source.sync_status == :failed
    assert failed_source.last_sync_result == :timeout
    assert failed_source.last_device_count == 1

    assert failed_source.last_error_message ==
             "partial armis sync after streaming 1 devices: context deadline exceeded"
  end

  def forward_repo_query(_event, _measurements, _metadata, test_pid) do
    send(test_pid, {:repo_query_pid, self()})
  end

  defp hold_general_permits(tasks) do
    parent = self()
    permits = :sys.get_state(WorkerBudget).limits.general

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
  end

  defp restore_queue_server({:ok, value}),
    do: Application.put_env(:serviceradar_core, :sync_ingestor_queue_server, value)

  defp restore_queue_server(:error),
    do: Application.delete_env(:serviceradar_core, :sync_ingestor_queue_server)

  defp drain_repo_query_pids(acc \\ []) do
    receive do
      {:repo_query_pid, pid} -> drain_repo_query_pids([pid | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp device_update(source, run, host_octet, index, total, final, population) do
    suffix = Integer.to_string(host_octet)
    hex = suffix |> String.pad_leading(2, "0") |> String.slice(-2, 2)

    %{
      "source" => "armis",
      "source_instance" => source,
      "device_id" => "armis:device#{suffix}",
      "ip" => "192.0.2.#{suffix}",
      "mac" => "02:00:00:00:00:#{hex}",
      "hostname" => "host#{suffix}.example.com",
      "is_available" => true,
      "metadata" => %{"armis_device_id" => "device#{suffix}", "integration_type" => "armis"},
      "sync_meta" => meta(source, run, index, total, final, population)
    }
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
