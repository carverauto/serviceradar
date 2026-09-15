defmodule ServiceRadar.AnalyticsStore.DeliveryReceiptDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.AnalyticsStore.ArchiveBatch
  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.DeliveryReceipt
  alias ServiceRadar.AnalyticsStore.HybridWriter
  alias ServiceRadar.AnalyticsStore.Layout
  alias ServiceRadar.AnalyticsStore.Query
  alias ServiceRadar.EventWriter.ArchivePublisher
  alias ServiceRadar.EventWriter.Processors.Metrics
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    key = Ecto.UUID.generate()
    {:ok, fixture: %{key: key, gateway: "archive-test-#{key}", stream: "TEST_METRICS_#{key}"}}
  end

  test "processing failure rolls back receipts, hot rows, archive payloads and jobs", %{
    fixture: fixture
  } do
    parent = self()
    messages = messages(fixture, [1, 2])

    assert {:error, error} =
             DeliveryReceipt.process_batch(Metrics, messages,
               config: config(),
               processor_fn: fn fresh ->
                 assert {:ok, 2} = write(fresh)
                 [batch_id] = batch_ids(fixture)
                 assert job_count(batch_id) == 1
                 send(parent, {:rolled_back_batch, batch_id})
                 {:error, :synthetic_processing_failure}
               end
             )

    assert Exception.message(error) =~ "synthetic_processing_failure"
    assert_receive {:rolled_back_batch, batch_id}
    assert hot_count(fixture) == 0
    assert receipt_count(messages) == 0
    assert batch_ids(fixture) == []
    assert job_count(batch_id) == 0
  end

  test "a full durable buffer rejects the delivery without committing hot rows or receipts", %{
    fixture: fixture
  } do
    messages = messages(fixture, [1])

    assert {:error, error} =
             DeliveryReceipt.process_batch(Metrics, messages,
               config: config(),
               processor_fn: &write(&1, config: %{config() | archive_buffer_max_bytes: 1})
             )

    assert Exception.message(error) =~ "archive_buffer_full"
    assert hot_count(fixture) == 0
    assert receipt_count(messages) == 0
    assert batch_ids(fixture) == []
  end

  test "regrouped deliveries and distinct deliveries of an existing hot row archive only new samples",
       %{fixture: fixture} do
    [a, b, c, d] = messages(fixture, [1, 2, 3, 4])
    assert {:ok, 2} = process([a, b])
    assert {:ok, 1} = process([b, c])
    assert {:ok, 0} = process([%{d | data: c.data}])

    assert hot_count(fixture) == 3
    assert receipt_count([a, b, c, d]) == 4
    assert [first, second] = batch_ids(fixture)
    assert {:ok, first_batch} = ArchiveBatch.fetch(first)
    assert {:ok, second_batch} = ArchiveBatch.fetch(second)
    assert {:ok, first_rows} = ArchiveBatch.decode_payload(first_batch)
    assert {:ok, second_rows} = ArchiveBatch.decode_payload(second_batch)
    archived = first_rows ++ second_rows
    assert length(archived) == 3

    assert archived |> Enum.map(& &1.series_key) |> Enum.sort() == [
             "series-1",
             "series-2",
             "series-3"
           ]

    assert job_count(first) == 1
    assert job_count(second) == 1
  end

  test "replaying an original delivery after hot deletion cannot create new archive work", %{
    fixture: fixture
  } do
    messages = messages(fixture, [1])
    assert {:ok, 1} = process(messages)
    [batch_id] = batch_ids(fixture)

    Repo.query!("DELETE FROM platform.timeseries_metrics WHERE gateway_id = $1", [fixture.gateway])

    assert hot_count(fixture) == 0

    assert {:ok, 0} = process(messages)
    assert receipt_count(messages) == 1
    assert hot_count(fixture) == 0
    assert batch_ids(fixture) == [batch_id]
    assert job_count(batch_id) == 1
  end

  test "receipt identity separates source scopes and missing identity fails before admission", %{
    fixture: fixture
  } do
    [message] = messages(fixture, [1])
    other = put_in(message.metadata.jetstream_ack.source_scope, "EXAMPLE_DOMAIN.EXAMPLE_ACCOUNT")

    assert {:ok, [^message, ^other]} =
             Repo.transaction(fn ->
               assert {:ok, fresh} = DeliveryReceipt.claim([message, other])
               fresh
             end)

    assert receipt_count([message, other]) == 2
    missing = %{message | metadata: %{}}
    assert {:error, error} = process([missing])
    assert Exception.message(error) =~ "missing_jetstream_identity"
    assert hot_count(fixture) == 0
    assert batch_ids(fixture) == []
  end

  @tag sandbox: :unboxed
  test "concurrent consumers admit one receipt group and one archive batch", %{fixture: fixture} do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()
    messages = messages(fixture, [1, 2])

    first =
      Task.Supervisor.async_nolink(supervisor, fn ->
        DeliveryReceipt.process_batch(Metrics, messages,
          config: config(),
          processor_fn: fn fresh ->
            send(parent, {:admitted, self()})

            receive do
              :commit -> write(fresh)
            after
              10_000 -> raise "test did not release the receipt transaction"
            end
          end
        )
      end)

    try do
      assert_receive {:admitted, first_pid}, 5_000

      second =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Repo.checkout(fn ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:second_consumer_started, backend})
            process(messages)
          end)
        end)

      try do
        assert_receive {:second_consumer_started, backend}, 5_000
        assert_receipt_lock_wait(backend, System.monotonic_time(:millisecond) + 5_000)
        send(first_pid, :commit)
        assert {:ok, 2} = Task.await(first, 10_000)
        assert {:ok, 0} = Task.await(second, 10_000)
        assert hot_count(fixture) == 2
        assert receipt_count(messages) == 2
        assert [batch_id] = batch_ids(fixture)
        assert job_count(batch_id) == 1
      after
        Task.shutdown(second, :brutal_kill)
      end
    after
      Task.shutdown(first, :brutal_kill)
      cleanup(fixture)
    end
  end

  @tag sandbox: :unboxed
  test "concurrent uploaded candidates expose one manifest and release the payload once", %{
    fixture: fixture
  } do
    supervisor = start_supervised!(Task.Supervisor)
    assert {:ok, 1} = process(messages(fixture, [1]))
    [batch_id] = batch_ids(fixture)
    parent = self()

    writer = fn table, rows, opts ->
      attrs = candidate(fixture, table, rows, opts)
      send(parent, {:candidate_ready, self(), attrs.object_key})

      receive do
        :publish ->
          assert :ok = opts[:record_manifest].(attrs)
          {:ok, length(rows)}
      after
        10_000 -> raise "test did not release candidate publication"
      end
    end

    tasks =
      for _ <- 1..2 do
        Task.Supervisor.async_nolink(supervisor, fn ->
          ArchivePublisher.publish(batch_id, writer: writer)
        end)
      end

    try do
      assert_receive {:candidate_ready, first_pid, first_key}, 5_000
      assert_receive {:candidate_ready, second_pid, second_key}, 5_000
      refute first_key == second_key
      send(first_pid, :publish)
      send(second_pid, :publish)
      assert Enum.map(tasks, &Task.await(&1, 10_000)) == [:ok, :ok]
      assert [published_key] = manifest_keys(batch_id)
      assert published_key in [first_key, second_key]

      assert {:ok,
              %{
                state: :published,
                payload: nil,
                payload_bytes: 0,
                published_object_key: ^published_key
              }} =
               ArchiveBatch.fetch(batch_id)
    after
      Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
      cleanup(fixture)
    end
  end

  test "an upload crash leaves durable payload and a retry publishes a different candidate once",
       %{fixture: fixture} do
    assert {:ok, 1} = process(messages(fixture, [1]))
    [batch_id] = batch_ids(fixture)
    parent = self()

    assert {:error, :synthetic_crash_after_upload} =
             ArchivePublisher.publish(batch_id,
               writer: fn table, rows, opts ->
                 send(parent, {:orphan_key, candidate(fixture, table, rows, opts).object_key})
                 {:error, :synthetic_crash_after_upload}
               end
             )

    assert_receive {:orphan_key, orphan}
    assert manifest_keys(batch_id) == []
    assert {:ok, %{state: :pending, payload: payload}} = ArchiveBatch.fetch(batch_id)
    assert is_binary(payload)

    assert :ok = publish(batch_id, fixture)
    assert [published] = manifest_keys(batch_id)
    refute published == orphan
    assert {:ok, %{state: :published, payload: nil}} = ArchiveBatch.fetch(batch_id)

    assert :ok =
             ArchivePublisher.publish(batch_id,
               writer: fn _, _, _ -> flunk("published batch uploaded again") end
             )

    assert manifest_keys(batch_id) == [published]
  end

  test "discarding a job retains its payload and reconciliation recreates publication work", %{
    fixture: fixture
  } do
    assert {:ok, 1} = process(messages(fixture, [1]))
    [batch_id] = batch_ids(fixture)
    assert {:ok, before} = ArchiveBatch.fetch(batch_id)

    assert %{num_rows: 1} =
             Repo.query!(
               "UPDATE platform.oban_jobs SET state = 'discarded', discarded_at = now() WHERE args->>'batch_id' = $1",
               [batch_id]
             )

    assert {:ok, after_discard} = ArchiveBatch.fetch(batch_id)
    assert after_discard.payload == before.payload
    assert after_discard.state == :pending

    assert :ok = ArchivePublisher.reconcile_pending()

    assert %{rows: [["available"], ["discarded"]]} =
             Repo.query!(
               "SELECT state::text FROM platform.oban_jobs WHERE args->>'batch_id' = $1 ORDER BY state::text",
               [
                 batch_id
               ]
             )

    assert :ok = publish(batch_id, fixture)
    assert length(manifest_keys(batch_id)) == 1
  end

  test "pending query gates use inclusive timestamp bounds and a fixed publication snapshot", %{
    fixture: fixture
  } do
    [a, b, c] = messages(fixture, [1, 2, 3])
    assert {:ok, 1} = process([a])
    assert {:ok, 1} = process([b])

    assert {:ok, ids} =
             ArchiveBatch.pending_ids_for_window(
               "timeseries_metrics",
               {a.data.timestamp, b.data.timestamp}
             )

    assert length(ids) == 2
    assert {:ok, false} = ArchiveBatch.published_ids?(ids)

    assert {:ok, []} =
             ArchiveBatch.pending_ids_for_window("timeseries_metrics", {c.data.timestamp, nil})

    assert {:ok, 1} = process([c])
    Enum.each(ids, fn id -> assert :ok = publish(id, fixture) end)
    assert {:ok, true} = ArchiveBatch.published_ids?(ids)

    assert {:ok, [remaining]} =
             ArchiveBatch.pending_ids_for_window("timeseries_metrics", {nil, nil})

    refute remaining in ids
    assert {:ok, false} = ArchiveBatch.published_ids?([remaining])
  end

  @tag sandbox: :unboxed
  test "an auxiliary SQL failure after commit leaves delivery and archive work durable", %{
    fixture: fixture
  } do
    messages = messages(fixture, [1])
    parent = self()

    try do
      assert {:ok, 1} =
               DeliveryReceipt.process_batch(Metrics, messages,
                 config: config(),
                 processor_fn: fn fresh ->
                   assert {:ok, count} = write(fresh)

                   {:ok, count,
                    fn ->
                      refute Repo.in_transaction?()
                      send(parent, :auxiliary_started_after_commit)
                      Repo.query!("SELECT 1 / 0")
                    end}
                 end
               )

      assert_receive :auxiliary_started_after_commit
      assert hot_count(fixture) == 1
      assert receipt_count(messages) == 1
      assert [batch_id] = batch_ids(fixture)
      assert job_count(batch_id) == 1
      assert {:ok, %{state: :pending, payload: payload}} = ArchiveBatch.fetch(batch_id)
      assert is_binary(payload)
      assert {:ok, 0} = process(messages)
      assert batch_ids(fixture) == [batch_id]
    after
      cleanup(fixture)
    end
  end

  test "reconciled batches rotate behind pending work that has not been revisited", %{
    fixture: fixture
  } do
    for message <- messages(fixture, [1, 2, 3]), do: assert({:ok, 1} = process([message]))
    assert {:ok, [first, second]} = ArchiveBatch.pending_ids(2)
    assert :ok = ArchiveBatch.mark_reconciled(first)
    assert :ok = ArchiveBatch.mark_reconciled(second)
    assert {:ok, [untouched, rotated]} = ArchiveBatch.pending_ids(2)
    refute untouched in [first, second]
    assert rotated in [first, second]
  end

  test "historical SQL waits for real pending work before selecting the published candidate", %{
    fixture: fixture
  } do
    [message] = messages(fixture, [1])
    assert {:ok, 1} = process([message])
    [batch_id] = batch_ids(fixture)
    cfg = %{config() | storage: :filesystem, filesystem_path: "/tmp/example-analytics"}
    window = {message.data.timestamp, message.data.timestamp}
    sql = "SELECT value FROM timeseries_metrics"

    assert {:error, :analytics_archive_not_ready} =
             Query.prepare("timeseries_metrics", sql, window,
               config: cfg,
               archive_wait_timeout: 200
             )

    assert manifest_keys(batch_id) == []

    assert :ok = publish(batch_id, fixture)
    assert [published_key] = manifest_keys(batch_id)
    assert {:ok, prepared} = Query.prepare("timeseries_metrics", sql, window, config: cfg)
    assert prepared =~ published_key
    assert prepared =~ "_candidates/date="
    refute prepared =~ "date=*"
  end

  defp config, do: %Config{driver: :hybrid, tables: MapSet.new(["timeseries_metrics"])}

  defp process(messages),
    do: DeliveryReceipt.process_batch(Metrics, messages, config: config(), processor_fn: &write/1)

  defp write(messages, opts \\ []) do
    HybridWriter.write(
      "timeseries_metrics",
      Enum.map(messages, & &1.data),
      Keyword.put_new(opts, :config, config())
    )
  end

  defp messages(fixture, sequences) do
    Enum.map(sequences, fn sequence ->
      timestamp = DateTime.add(~U[2034-01-02 12:00:00.000000Z], sequence, :second)

      %{
        data: %{
          timestamp: timestamp,
          gateway_id: fixture.gateway,
          agent_id: "example-agent",
          metric_name: "synthetic_counter",
          metric_type: "snmp",
          device_id: "example-device",
          value: sequence * 10.0,
          unit: "bytes",
          tags: %{},
          partition: "example-partition",
          scale: 1.0,
          is_delta: false,
          target_device_ip: nil,
          if_index: 7,
          metadata: %{},
          created_at: timestamp,
          series_key: "series-#{sequence}",
          counter_width: 64
        },
        metadata: %{
          jetstream_ack: %{
            stream: fixture.stream,
            stream_sequence: sequence,
            timestamp: 2_000_000_000 + sequence,
            source_scope: ""
          }
        }
      }
    end)
  end

  defp hot_count(fixture) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM platform.timeseries_metrics WHERE gateway_id = $1", [
        fixture.gateway
      ])

    count
  end

  defp receipt_count(messages) do
    ids =
      Enum.map(messages, fn message ->
        {:ok, id} = DeliveryReceipt.identity(message)
        id
      end)

    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.analytics_delivery_receipts WHERE id = ANY($1::text[])",
        [ids]
      )

    count
  end

  defp batch_ids(fixture) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT id::text FROM platform.analytics_archive_batches
        WHERE (payload IS NOT NULL AND convert_from(payload, 'UTF8')::jsonb->'rows' @> jsonb_build_array(jsonb_build_object('gateway_id', $1::text)))
           OR published_object_key LIKE $2
        ORDER BY inserted_at, id
        """,
        [fixture.gateway, "%/test-#{fixture.key}-%"]
      )

    Enum.map(rows, &hd/1)
  end

  defp job_count(batch_id) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM platform.oban_jobs WHERE args->>'batch_id' = $1", [
        batch_id
      ])

    count
  end

  defp manifest_keys(batch_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT object_key FROM platform.analytics_file_manifest WHERE archive_batch_id = ($1::text)::uuid",
        [
          batch_id
        ]
      )

    Enum.map(rows, &hd/1)
  end

  defp candidate(fixture, table, rows, opts) do
    assert opts[:candidate]

    keys =
      Layout.candidate_keys(
        table,
        DateTime.to_date(hd(rows).timestamp),
        "test-#{fixture.key}",
        opts[:batch_id]
      )

    timestamps = Enum.map(rows, & &1.timestamp)

    %{
      table_name: table,
      object_key: keys.published_key,
      staging_key: keys.staging_key,
      partition_date: DateTime.to_date(hd(rows).timestamp),
      row_count: length(rows),
      min_timestamp: Enum.min(timestamps, DateTime),
      max_timestamp: Enum.max(timestamps, DateTime),
      batch_id: opts[:batch_id],
      status: :published
    }
  end

  defp publish(batch_id, fixture) do
    ArchivePublisher.publish(batch_id,
      writer: fn table, rows, opts ->
        assert :ok = opts[:record_manifest].(candidate(fixture, table, rows, opts))
        {:ok, length(rows)}
      end
    )
  end

  defp cleanup(fixture) do
    ids = batch_ids(fixture)
    Repo.query!("DELETE FROM platform.oban_jobs WHERE args->>'batch_id' = ANY($1::text[])", [ids])

    Repo.query!(
      "DELETE FROM platform.analytics_file_manifest WHERE archive_batch_id::text = ANY($1::text[])",
      [ids]
    )

    Repo.query!(
      "DELETE FROM platform.analytics_archive_batches WHERE id::text = ANY($1::text[])",
      [ids]
    )

    receipt_ids =
      Enum.map(messages(fixture, [1, 2]), fn message ->
        {:ok, id} = DeliveryReceipt.identity(message)
        id
      end)

    Repo.query!("DELETE FROM platform.analytics_delivery_receipts WHERE id = ANY($1::text[])", [
      receipt_ids
    ])

    Repo.query!("DELETE FROM platform.timeseries_metrics WHERE gateway_id = $1", [fixture.gateway])
  end

  defp assert_receipt_lock_wait(backend, deadline) do
    %{rows: [[waiting]]} =
      Repo.query!("SELECT EXISTS(SELECT 1 FROM pg_locks WHERE pid = $1 AND NOT granted)", [
        backend
      ])

    if not waiting do
      assert System.monotonic_time(:millisecond) < deadline,
             "second consumer never waited on the first receipt transaction"

      receive do
      after
        10 -> assert_receipt_lock_wait(backend, deadline)
      end
    end
  end
end
