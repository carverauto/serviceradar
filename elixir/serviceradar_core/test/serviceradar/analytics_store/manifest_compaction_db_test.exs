defmodule ServiceRadar.AnalyticsStore.ManifestCompactionDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AnalyticsStore.ArchiveBatch
  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.FileManifest
  alias ServiceRadar.AnalyticsStore.Layout
  alias ServiceRadar.EventWriter.ArchivePublisher
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration
  @moduletag sandbox: :unboxed
  @table "timeseries_metrics"
  @start ~U[2034-02-03 12:00:00.000000Z]

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    key = Ecto.UUID.generate()
    on_exit(fn -> cleanup(key) end)
    {:ok, key: key}
  end

  test "publication changes the whole visible set at commit and retains source lineage", %{
    key: key
  } do
    sources = Enum.map([1, 2], &source(key, &1))
    target = target(key, sources)
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Ash.transact(FileManifest, fn ->
          assert :ok = FileManifest.replace_sources(sources, target)
          send(parent, {:replacement_ready, self()})

          receive do
            :commit -> :ok
          after
            10_000 -> raise "test did not release manifest commit"
          end
        end)
      end)

    try do
      assert_receive {:replacement_ready, writer}, 5_000
      assert visible(key) == keys(sources)
      late = source(key, 3)
      send(writer, :commit)
      assert {:ok, :ok} = Task.await(task, 10_000)
      assert visible(key) == Enum.sort([target.object_key, late.object_key])

      for original <- sources do
        retained = fetch(original.object_key)
        assert retained.status == :superseded
        assert retained.archive_batch_id == original.archive_batch_id
        assert retained.replacement_key == target.object_key
        assert retained.retired_at
        assert {:ok, %{state: :published}} = ArchiveBatch.fetch(retained.archive_batch_id)
      end

      assert fetch(target.object_key).archive_batch_id == nil
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "racing compactors lock the same snapshot and only one candidate becomes visible", %{
    key: key
  } do
    sources = Enum.map([1, 2], &source(key, &1))
    first_target = target(key, sources)
    second_target = target(key, sources)
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)

    first =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Ash.transact(FileManifest, fn ->
          Repo.query!(
            "SELECT id FROM platform.analytics_file_manifest WHERE id = ANY($1::bigint[]) ORDER BY id FOR UPDATE",
            [Enum.map(sources, & &1.id)]
          )

          send(parent, {:sources_locked, self()})

          receive do
            :publish -> FileManifest.replace_sources(sources, first_target)
          after
            10_000 -> raise "test did not release source locks"
          end
        end)
      end)

    try do
      assert_receive {:sources_locked, first_pid}, 5_000

      second =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Repo.checkout(fn ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:second_backend, backend})
            FileManifest.replace_sources(sources, second_target)
          end)
        end)

      try do
        assert_receive {:second_backend, backend}, 5_000
        assert_lock_wait(backend, System.monotonic_time(:millisecond) + 5_000)
        send(first_pid, :publish)
        assert {:ok, :ok} = Task.await(first, 10_000)
        assert {:error, _} = Task.await(second, 10_000)
        assert visible(key) == [first_target.object_key]
        assert fetch(second_target.object_key) == nil
      after
        Task.shutdown(second, :brutal_kill)
      end
    after
      Task.shutdown(first, :brutal_kill)
    end
  end

  test "invalid count checksum and timestamp bounds cannot replace published sources", %{key: key} do
    sources = Enum.map([1, 2], &source(key, &1))
    target = target(key, sources)

    for invalid <- [
          %{target | row_count: target.row_count - 1},
          %{target | content_checksum: ""},
          %{target | min_timestamp: DateTime.add(target.min_timestamp, 1)},
          %{target | max_timestamp: DateTime.add(target.max_timestamp, 1)}
        ] do
      assert {:error, :compaction_candidate_mismatch} =
               FileManifest.replace_sources(sources, invalid)

      assert visible(key) == keys(sources)
      assert fetch(target.object_key) == nil
    end
  end

  test "a target key collision rolls back replacement without overwriting the existing object", %{
    key: key
  } do
    sources = Enum.map([1, 2], &source(key, &1))
    unrelated = source(key, 3)

    target = %{
      target(key, sources)
      | object_key: unrelated.object_key,
        staging_key: unrelated.object_key
    }

    assert {:error, _} = FileManifest.replace_sources(sources, target)
    assert visible(key) == keys([unrelated | sources])
    assert fetch(unrelated.object_key) == unrelated
    assert Enum.all?(sources, &(fetch(&1.object_key).status == :published))
  end

  test "a changed source snapshot rejects publication and leaves its current version visible", %{
    key: key
  } do
    [first | _] = sources = Enum.map([1, 2], &source(key, &1))
    target = target(key, sources)

    changed =
      first |> Map.take(source_fields()) |> Map.put(:content_checksum, String.duplicate("b", 64))

    assert :ok = FileManifest.record(changed)

    assert {:error, _} = FileManifest.replace_sources(sources, target)
    assert visible(key) == keys(sources)
    assert fetch(first.object_key).content_checksum == changed.content_checksum
    assert fetch(target.object_key) == nil
  end

  test "replaying a retired snapshot cannot resurrect its sources or publish another candidate",
       %{key: key} do
    sources = Enum.map([1, 2], &source(key, &1))
    target = target(key, sources)
    retry = target(key, sources)
    assert :ok = FileManifest.replace_sources(sources, target)
    assert {:error, _} = FileManifest.replace_sources(sources, retry)
    assert visible(key) == [target.object_key]
    assert fetch(retry.object_key) == nil
    assert Enum.all?(sources, &(fetch(&1.object_key).status == :superseded))
  end

  test "retired source membership survives deletion marking after the reader grace", %{key: key} do
    [first | _] = sources = Enum.map([1, 2], &source(key, &1))
    now = DateTime.utc_now()
    assert :ok = FileManifest.replace_sources(sources, target(key, sources), now: now)

    assert {:error, :compaction_reader_grace_active} =
             FileManifest.mark_objects_deleted(first.id, now: now)

    later = DateTime.add(now, 86_400)
    assert :ok = FileManifest.mark_objects_deleted(first.id, now: later)
    retained = fetch(first.object_key)
    assert retained.status == :superseded
    assert retained.archive_batch_id == first.archive_batch_id
    assert retained.objects_deleted_at == later
  end

  test "explicit single-file rewrite preserves its envelope and archive lineage", %{key: key} do
    original = source(key, 1)
    attrs = original |> Map.take(source_fields()) |> Map.put(:row_count, 700_001)
    assert :ok = FileManifest.record(attrs)
    original = fetch(original.object_key)
    now = ~U[2040-01-01 00:00:00Z]
    opts = [now: now]
    assert {:ok, ^original} = FileManifest.rewrite_source(@table, original.id, opts)
    target = rewrite_target(key, original)

    assert :ok = FileManifest.replace_rewrite(original, target, opts)
    assert visible(key) == [target.object_key]
    replacement = fetch(target.object_key)
    assert replacement.row_count == original.row_count
    assert replacement.min_timestamp == original.min_timestamp
    assert replacement.max_timestamp == original.max_timestamp
    assert replacement.archive_batch_id == nil
    retired = fetch(original.object_key)
    assert retired.status == :superseded
    assert retired.archive_batch_id == original.archive_batch_id
    assert retired.replacement_key == target.object_key
    assert DateTime.compare(retired.retired_at, now) == :eq

    assert {:error, :compaction_reader_grace_active} =
             FileManifest.mark_objects_deleted(original.id, now: now)

    assert {:error, :invalid_rewrite_source} =
             FileManifest.rewrite_source(@table, original.id, opts)

    assert {:error, :rewrite_source_already_sorted} =
             FileManifest.rewrite_source(@table, replacement.id, opts)

    assert {:error, _} =
             FileManifest.replace_rewrite(original, rewrite_target(key, original), opts)

    assert visible(key) == [target.object_key]
  end

  test "competing single-file rewrites publish only one target under a real row lock", %{key: key} do
    original = source(key, 1)
    first_target = rewrite_target(key, original)
    second_target = rewrite_target(key, original)
    opts = [now: ~U[2040-01-01 00:00:00Z]]
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)

    first =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Ash.transact(FileManifest, fn ->
          Repo.query!(
            "SELECT id FROM platform.analytics_file_manifest WHERE id = $1 FOR UPDATE",
            [original.id]
          )

          send(parent, {:rewrite_locked, self()})

          receive do
            :publish -> FileManifest.replace_rewrite(original, first_target, opts)
          after
            10_000 -> raise "test did not release rewrite lock"
          end
        end)
      end)

    try do
      assert_receive {:rewrite_locked, writer}, 5_000

      second =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Repo.checkout(fn ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:rewrite_backend, backend})
            FileManifest.replace_rewrite(original, second_target, opts)
          end)
        end)

      try do
        assert_receive {:rewrite_backend, backend}, 5_000
        assert_lock_wait(backend, System.monotonic_time(:millisecond) + 5_000)
        send(writer, :publish)
        assert {:ok, :ok} = Task.await(first, 10_000)
        assert {:error, _} = Task.await(second, 10_000)
        assert visible(key) == [first_target.object_key]
        assert fetch(second_target.object_key) == nil
      after
        Task.shutdown(second, :brutal_kill)
      end
    after
      Task.shutdown(first, :brutal_kill)
    end
  end

  test "single-file publication rejects missing, changed, and mismatched sources", %{key: key} do
    opts = [now: ~U[2040-01-01 00:00:00Z]]

    assert {:error, :invalid_rewrite_source} =
             FileManifest.rewrite_source(@table, 9_000_000_000_000_000_001, opts)

    original = source(key, 1)
    target = rewrite_target(key, original)

    assert {:error, :compaction_candidate_mismatch} =
             FileManifest.replace_rewrite(
               original,
               %{target | row_count: original.row_count + 1},
               opts
             )

    assert visible(key) == [original.object_key]

    changed =
      original
      |> Map.take(source_fields())
      |> Map.put(:content_checksum, String.duplicate("b", 64))

    assert :ok = FileManifest.record(changed)
    assert {:error, _} = FileManifest.replace_rewrite(original, target, opts)
    assert fetch(target.object_key) == nil
    assert visible(key) == [original.object_key]
  end

  test "candidate selection skips more than 1024 singleton partitions before applying its limit",
       %{key: key} do
    table = "synthetic_compaction_#{key}"
    singletons = for day <- 0..1_024, do: plain_attrs(key, table, Date.add(~D[2030-01-01], day))
    now = ~U[2040-01-01 00:00:00Z]

    pair =
      for _ <- 1..2 do
        key
        |> plain_attrs(table, ~D[2039-12-31])
        |> Map.merge(%{
          min_timestamp: DateTime.add(now, -90, :second),
          max_timestamp: DateTime.add(now, -61, :second)
        })
      end

    fresh =
      for _ <- 1..2 do
        key
        |> plain_attrs(table, ~D[2039-12-31])
        |> Map.merge(%{
          min_timestamp: DateTime.add(now, -59, :second),
          max_timestamp: DateTime.add(now, -59, :second)
        })
      end

    oversized =
      for _ <- 1..2, do: Map.put(plain_attrs(key, table, ~D[2033-01-01]), :row_count, 250_001)

    assert %Ash.BulkResult{status: :success, error_count: 0} =
             Ash.bulk_create(singletons ++ oversized ++ pair ++ fresh, FileManifest, :record,
               actor: SystemActor.system(:test),
               upsert_fields: [],
               return_errors?: true,
               stop_on_error?: true
             )

    assert {:ok, selected} =
             FileManifest.compaction_candidates(table, now: now)

    assert keys(selected) == keys(pair)
  end

  @tag sandbox: :transaction
  test "expiration hides published files while retaining archive lineage and reader grace", %{
    key: key
  } do
    sources = Enum.map([1, 2], &source(key, &1))
    now = DateTime.utc_now()
    cutoff = Date.add(DateTime.to_date(@start), 1)

    assert {:error, :hybrid_archive_retention_required} =
             FileManifest.ensure_legacy_prune_allowed(@table)

    legacy_keys = FileManifest.expired_keys(@table, cutoff)

    for original <- sources do
      refute original.object_key in legacy_keys
      assert :ok = FileManifest.forget(original.object_key)
      assert fetch(original.object_key).archive_batch_id == original.archive_batch_id
    end

    assert {:ok, count} =
             FileManifest.retire_expired(@table, cutoff, now: now)

    assert count >= length(sources)
    assert visible(key) == []

    for original <- sources do
      retired = fetch(original.object_key)
      assert retired.status == :expired
      assert retired.archive_batch_id == original.archive_batch_id
      assert retired.replacement_key == nil
      assert retired.retired_at == now
      assert {:ok, %{state: :published}} = ArchiveBatch.fetch(retired.archive_batch_id)

      assert {:error, :compaction_reader_grace_active} =
               FileManifest.mark_objects_deleted(retired.id, now: now)

      assert :ok = FileManifest.mark_objects_deleted(retired.id, now: DateTime.add(now, 86_400))
      assert fetch(original.object_key).archive_batch_id == original.archive_batch_id
    end
  end

  test "expiration wins a source lock race without letting a captured compaction snapshot republish it",
       %{key: key} do
    table = "synthetic_compaction_#{key}"

    sources =
      for _ <- 1..2 do
        attrs = plain_attrs(key, table, DateTime.to_date(@start))
        assert :ok = FileManifest.record(attrs)
        fetch(attrs.object_key)
      end

    target = target(key, sources)
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)

    expiry =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Ash.transact(FileManifest, fn ->
          assert {:ok, 2} =
                   FileManifest.retire_expired(table, Date.add(DateTime.to_date(@start), 1))

          send(parent, {:expiry_locked, self()})

          receive do
            :commit -> :ok
          after
            10_000 -> raise "test did not release expiry transaction"
          end
        end)
      end)

    try do
      assert_receive {:expiry_locked, writer}, 5_000

      compactor =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Repo.checkout(fn ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:compactor_backend, backend})
            FileManifest.replace_sources(sources, target)
          end)
        end)

      try do
        assert_receive {:compactor_backend, backend}, 5_000
        assert_lock_wait(backend, System.monotonic_time(:millisecond) + 5_000)
        send(writer, :commit)
        assert {:ok, :ok} = Task.await(expiry, 10_000)
        assert {:error, _} = Task.await(compactor, 10_000)
        assert {:ok, []} = FileManifest.published_keys(table, nil, nil)
        assert Enum.all?(sources, &(fetch(&1.object_key).status == :expired))
        assert fetch(target.object_key) == nil
      after
        Task.shutdown(compactor, :brutal_kill)
      end
    after
      Task.shutdown(expiry, :brutal_kill)
    end
  end

  defp source(key, sequence) do
    timestamp = DateTime.add(@start, sequence, :minute)

    row = %{
      timestamp: timestamp,
      gateway_id: "synthetic-#{key}",
      series_key: "series-#{sequence}",
      metric_name: "synthetic_counter",
      metric_type: "snmp",
      agent_id: "example-agent",
      device_id: "example-device",
      value: sequence * 10.0,
      unit: "bytes",
      partition: "example-partition",
      scale: 1.0,
      is_delta: false,
      target_device_ip: nil,
      if_index: 7,
      counter_width: 64,
      tags: %{},
      metadata: %{},
      created_at: timestamp
    }

    cfg = %Config{driver: :hybrid, tables: MapSet.new([@table])}

    assert {:ok, 1} =
             ArchiveBatch.enqueue_rows(@table, [row],
               config: cfg,
               enqueue_job: fn id ->
                 send(self(), {:batch, id})
                 {:ok, id}
               end
             )

    assert_receive {:batch, id}

    assert :ok =
             ArchivePublisher.publish(id,
               writer: fn table, rows, opts ->
                 keys =
                   Layout.candidate_keys(
                     table,
                     DateTime.to_date(timestamp),
                     "compact-test-#{key}",
                     opts[:batch_id]
                   )

                 attrs = %{
                   table_name: table,
                   object_key: keys.published_key,
                   staging_key: keys.staging_key,
                   partition_date: DateTime.to_date(timestamp),
                   row_count: length(rows),
                   min_timestamp: timestamp,
                   max_timestamp: timestamp,
                   batch_id: opts[:batch_id],
                   status: :published,
                   content_checksum: String.duplicate("a", 64)
                 }

                 assert :ok = opts[:record_manifest].(attrs)
                 send(self(), {:published, attrs.object_key})
                 {:ok, length(rows)}
               end
             )

    assert_receive {:published, object_key}
    fetch(object_key)
  end

  defp target(key, sources) do
    first = hd(sources)

    keys =
      Layout.candidate_keys(
        first.table_name,
        first.partition_date,
        "compact-test-#{key}",
        Ecto.UUID.generate()
      )

    %{
      table_name: first.table_name,
      object_key: keys.published_key,
      staging_key: keys.published_key,
      partition_date: first.partition_date,
      row_count: Enum.sum(Enum.map(sources, & &1.row_count)),
      min_timestamp:
        Enum.min_by(sources, &DateTime.to_unix(&1.min_timestamp, :microsecond)).min_timestamp,
      max_timestamp:
        Enum.max_by(sources, &DateTime.to_unix(&1.max_timestamp, :microsecond)).max_timestamp,
      batch_id: Ecto.UUID.generate(),
      content_checksum: String.duplicate("c", 64),
      status: :published
    }
  end

  defp rewrite_target(key, source) do
    key
    |> target([source])
    |> Map.put(:content_checksum, "row-hash-v1:" <> String.duplicate("c", 64))
  end

  defp plain_attrs(key, table, date) do
    {:ok, timestamp} = DateTime.new(date, ~T[12:00:00], "Etc/UTC")
    keys = Layout.candidate_keys(table, date, "compact-test-#{key}", Ecto.UUID.generate())

    %{
      table_name: table,
      partition_date: date,
      object_key: keys.published_key,
      staging_key: keys.staging_key,
      min_timestamp: timestamp,
      max_timestamp: timestamp,
      row_count: 1,
      batch_id: Ecto.UUID.generate(),
      status: :published,
      content_checksum: String.duplicate("a", 64)
    }
  end

  defp source_fields,
    do: [
      :table_name,
      :object_key,
      :staging_key,
      :partition_date,
      :row_count,
      :min_timestamp,
      :max_timestamp,
      :batch_id,
      :archive_batch_id,
      :content_checksum,
      :status
    ]

  defp fetch(key) do
    FileManifest
    |> Ash.Query.filter(object_key == ^key)
    |> Ash.read_one!(actor: SystemActor.system(:test))
  end

  defp keys(sources), do: sources |> Enum.map(& &1.object_key) |> Enum.sort()

  defp visible(key) do
    {:ok, keys} = FileManifest.published_keys(@table, @start, DateTime.add(@start, 3600))
    keys |> Enum.filter(&String.contains?(&1, "compact-test-#{key}-")) |> Enum.sort()
  end

  defp cleanup(key) do
    pattern = "%/compact-test-#{key}-%"

    %{rows: ids} =
      Repo.query!(
        """
        SELECT id::text FROM platform.analytics_archive_batches
        WHERE published_object_key LIKE $1
           OR (payload IS NOT NULL AND convert_from(payload, 'UTF8')::jsonb->'rows'
               @> jsonb_build_array(jsonb_build_object('gateway_id', $2::text)))
        """,
        [pattern, "synthetic-#{key}"]
      )

    Repo.query!("DELETE FROM platform.analytics_file_manifest WHERE object_key LIKE $1", [pattern])

    Repo.query!(
      "DELETE FROM platform.analytics_archive_batches WHERE id::text = ANY($1::text[])",
      [Enum.map(ids, &hd/1)]
    )
  end

  defp assert_lock_wait(backend, deadline) do
    %{rows: [[waiting]]} =
      Repo.query!("SELECT EXISTS(SELECT 1 FROM pg_locks WHERE pid = $1 AND NOT granted)", [
        backend
      ])

    if !waiting do
      assert System.monotonic_time(:millisecond) < deadline,
             "second compactor never waited on source locks"

      receive do
      after
        10 -> assert_lock_wait(backend, deadline)
      end
    end
  end
end
