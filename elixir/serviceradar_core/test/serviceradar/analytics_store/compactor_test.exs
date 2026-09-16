defmodule ServiceRadar.AnalyticsStore.CompactorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.CompactionWorker
  alias ServiceRadar.AnalyticsStore.Compactor
  alias ServiceRadar.AnalyticsStore.Config

  @time ~U[2034-01-02 03:00:00.000000Z]
  @table "timeseries_metrics"

  defp cfg do
    Config.load(
      driver: :hybrid,
      tables: @table,
      storage: :filesystem,
      filesystem_path: "/synthetic/analytics"
    )
  end

  defp source(id, changes \\ %{}) do
    Map.merge(
      %{
        id: id,
        table_name: @table,
        object_key: "analytics/v1/#{@table}/date=2034-01-02/synthetic-#{id}.parquet",
        staging_key: "analytics/v1/#{@table}/_staging/synthetic-#{id}.parquet",
        partition_date: ~D[2034-01-02],
        row_count: 2,
        min_timestamp: @time,
        max_timestamp: DateTime.add(@time, 30),
        inserted_at: @time,
        content_checksum: "synthetic-legacy-checksum",
        status: :published
      },
      changes
    )
  end

  defp check(changes \\ %{}) do
    Map.merge(
      %{
        "row_count" => 4,
        "min_epoch" => Integer.to_string(DateTime.to_unix(@time, :microsecond)),
        "max_epoch" => Integer.to_string(DateTime.to_unix(DateTime.add(@time, 30), :microsecond)),
        "hash_xor" => "0",
        "hash_sum" => "18446744073709551620"
      },
      changes
    )
  end

  defp options(overrides \\ []) do
    defaults = [
      config: cfg(),
      candidates: fn @table, _ -> {:ok, [source(1), source(2)]} end,
      session: fn _, fun ->
        send(self(), :session)
        {:ok, fun.(:conn)}
      end,
      query: query(),
      replace_sources: fn sources, attrs, _ ->
        send(self(), {:replace, sources, attrs})
        :ok
      end
    ]

    Keyword.merge(defaults, overrides)
  end

  defp query(opts \\ []) do
    fn :conn, sql, [] ->
      send(self(), {:query, sql})

      cond do
        String.contains?(sql, "pg_stat_activity") ->
          %Postgrex.Result{rows: [[Keyword.get(opts, :active, 0)]]}

        String.contains?(sql, "duckdb.query(") ->
          verification =
            if String.contains?(sql, "FROM analytics_compaction") do
              Keyword.get(opts, :source_check, check())
            else
              Keyword.get(opts, :target_check, check())
            end

          %Postgrex.Result{rows: [[Jason.encode!(verification)]]}

        true ->
          %Postgrex.Result{rows: []}
      end
    end
  end

  test "one canonical materialization and verified sorted candidate precede atomic replacement" do
    assert {:ok, %{source_files: 2, row_count: 4}} = Compactor.run(@table, options())
    assert_received {:replace, sources, attrs}
    assert Enum.map(sources, & &1.id) == [1, 2]
    assert attrs.row_count == 4
    assert attrs.min_timestamp == @time
    assert attrs.max_timestamp == DateTime.add(@time, 30)
    assert attrs.staging_key == attrs.object_key
    assert attrs.object_key =~ "/_candidates/date=2034-01-02/compact-"
    assert attrs.content_checksum =~ ~r/\Arow-hash-v1:[0-9a-f]{64}\z/
    assert attrs.archive_batch_id == nil

    sql = drain_sql()
    assert Enum.count(sql, &String.contains?(&1, "CREATE TEMP TABLE")) == 1
    assert Enum.count(sql, &String.contains?(&1, "COPY (")) == 1
    assert Enum.count(sql, &String.contains?(&1, "duckdb.query(")) == 2
    assert Enum.any?(sql, &String.contains?(&1, "ORDER BY device_id, metric_name, timestamp"))
    assert Enum.any?(sql, &String.contains?(&1, ~s|CAST("timestamp" AS timestamptz)|))
    assert Enum.any?(sql, &String.contains?(&1, ~s|CAST("metadata" AS VARCHAR)|))
    assert Enum.any?(sql, &String.contains?(&1, "bit_xor(hash("))
    assert Enum.any?(sql, &String.contains?(&1, "sum(hash("))

    refute Enum.any?(
             sql,
             &String.contains?(&1, ["date=*", "DISTINCT", "ROW_NUMBER", "ROW_GROUP_SIZE"])
           )
  end

  test "retries use different candidate keys while retaining the same source snapshot" do
    assert {:ok, _} = Compactor.run(@table, options())
    assert_received {:replace, sources, first}
    assert {:ok, _} = Compactor.run(@table, options())
    assert_received {:replace, ^sources, second}
    refute first.object_key == second.object_key
    assert first.content_checksum == second.content_checksum
  end

  test "missing or altered source rows fail before any object COPY" do
    for changes <- [%{"row_count" => 3}, %{"min_epoch" => "0"}] do
      assert {:error, :compaction_source_mismatch} =
               Compactor.run(@table, options(query: query(source_check: check(changes))))

      refute_received {:replace, _, _}
      refute Enum.any?(drain_sql(), &String.contains?(&1, "COPY ("))
    end
  end

  test "candidate row count and both hash aggregates must match before publication" do
    for changes <- [%{"row_count" => 2}, %{"hash_xor" => "1"}, %{"hash_sum" => "2"}] do
      assert {:error, :compaction_verification_mismatch} =
               Compactor.run(@table, options(query: query(target_check: check(changes))))

      refute_received {:replace, _, _}
    end
  end

  test "a changed manifest snapshot propagates failure and never republishes the source set" do
    assert {:error, :compaction_sources_changed} =
             Compactor.run(
               @table,
               options(replace_sources: fn _, _, _ -> {:error, :compaction_sources_changed} end)
             )
  end

  test "source group bounds and concrete-key requirement fail before opening a head connection" do
    for sources <- [
          [source(1)],
          Enum.map(1..257, &source/1),
          [source(1, %{row_count: 300_000}), source(2, %{row_count: 300_000})],
          [source(1), source(2, %{partition_date: ~D[2034-01-03]})],
          [source(1), source(2, %{max_timestamp: DateTime.add(@time, 86_400)})],
          [source(1), source(2, %{object_key: "analytics/v1/#{@table}/date=*/*.parquet"})]
        ] do
      assert {:error, _} =
               Compactor.run(@table, options(candidates: fn _, _ -> {:ok, sources} end))

      refute_received :session
    end
  end

  test "a busy head defers before reading any Parquet objects" do
    assert {:error, :analytics_head_busy} =
             Compactor.run(@table, options(query: query(active: 2)))

    refute_received {:replace, _, _}
    refute Enum.any?(drain_sql(), &String.contains?(&1, "read_parquet"))
  end

  test "disabled stores and empty snapshots do not open a connection" do
    for driver <- [:timescale, :pg_duckdb] do
      assert {:ok, :disabled} = Compactor.run(@table, options(config: %{cfg() | driver: driver}))
    end

    assert {:ok, :no_candidates} =
             Compactor.run(@table, options(candidates: fn _, _ -> {:ok, []} end))

    assert {:error, :unsupported_compaction_table} =
             Compactor.run("ocsf_network_activity", options())

    refute_received :session
  end

  test "worker preserves errors and snoozes contention on the shared low-priority queue" do
    assert :ok = CompactionWorker.compact(@table, run: fn _, _ -> {:ok, :disabled} end)

    assert {:snooze, 60} =
             CompactionWorker.compact(@table, run: fn _, _ -> {:error, :analytics_head_busy} end)

    assert {:error, :storage_unavailable} =
             CompactionWorker.compact(@table, run: fn _, _ -> {:error, :storage_unavailable} end)

    changeset = CompactionWorker.new(%{table: @table})
    assert Ecto.Changeset.get_field(changeset, :queue) == "analytics_archive"
    assert Ecto.Changeset.get_field(changeset, :priority) == 3
  end

  test "explicit large-file rewrite preserves all rows with the same sorted and verified IO path" do
    rows = 7_000_003
    source = source(1, %{row_count: rows})
    check = check(%{"row_count" => rows})

    opts =
      rewrite_options(source,
        query: query(source_check: check, target_check: check),
        replace_rewrite: fn ^source, attrs, _ ->
          send(self(), {:rewritten, attrs})
          :ok
        end
      )

    assert {:ok, %{source_files: 1, row_count: ^rows}} = Compactor.rewrite_file(@table, 1, opts)
    assert_received {:rewritten, attrs}
    assert attrs.row_count == rows
    assert attrs.object_key =~ "/rewrite-"
    assert attrs.staging_key == attrs.object_key
    assert attrs.content_checksum =~ ~r/\Arow-hash-v1:[0-9a-f]{64}\z/
    assert attrs.archive_batch_id == nil
    sql = drain_sql()
    assert Enum.count(sql, &String.contains?(&1, "CREATE TEMP TABLE")) == 1
    assert Enum.count(sql, &String.contains?(&1, "COPY (")) == 1
    assert Enum.any?(sql, &String.contains?(&1, "statement_timeout = '120000'"))
    assert Enum.any?(sql, &String.contains?(&1, "ORDER BY device_id, metric_name, timestamp"))
    refute Enum.any?(sql, &String.contains?(&1, ["DISTINCT", "ROW_NUMBER", "date=*"]))
  end

  test "explicit rewrite rejects unsuitable snapshots before opening the head" do
    for source <- [
          nil,
          source(1, %{status: :superseded}),
          source(1, %{status: :expired}),
          source(1, %{row_count: 10_000_001}),
          source(1, %{min_timestamp: nil}),
          source(1, %{max_timestamp: DateTime.add(@time, 86_400)}),
          source(1, %{inserted_at: DateTime.add(@time, 3599)}),
          source(1, %{content_checksum: "row-hash-v1:" <> String.duplicate("a", 64)}),
          source(1, %{object_key: "analytics/v1/#{@table}/date=*/*.parquet"})
        ] do
      assert {:error, _} = Compactor.rewrite_file(@table, 1, rewrite_options(source))
      refute_received :session
    end
  end

  test "explicit rewrite requires hybrid and propagates missing or stale publication errors" do
    opts = rewrite_options(source(1))

    for driver <- [:timescale, :pg_duckdb] do
      assert {:error, :rewrite_requires_hybrid} =
               Compactor.rewrite_file(
                 @table,
                 1,
                 Keyword.put(opts, :config, %{cfg() | driver: driver})
               )
    end

    assert {:error, :invalid_rewrite_source} =
             Compactor.rewrite_file(
               @table,
               1,
               Keyword.put(opts, :source, fn _, _, _ -> {:error, :invalid_rewrite_source} end)
             )

    refute_received :session

    two_rows = check(%{"row_count" => 2})

    assert {:error, :compaction_sources_changed} =
             Compactor.rewrite_file(
               @table,
               1,
               rewrite_options(source(1),
                 query: query(source_check: two_rows, target_check: two_rows),
                 replace_rewrite: fn _, _, _ -> {:error, :compaction_sources_changed} end
               )
             )
  end

  test "invalid rewrite IDs fail before loading a source or opening the head" do
    opts = options(source: fn _, _, _ -> flunk("invalid ID reached manifest lookup") end)

    for id <- [nil, 0, -1, "1", 1.0] do
      assert {:error, :invalid_rewrite_manifest_id} = Compactor.rewrite_file(@table, id, opts)
    end

    refute_received :session
  end

  test "explicit rewrite retains head-idle and full-row verification gates" do
    source = source(1)

    assert {:error, :analytics_head_busy} =
             Compactor.rewrite_file(@table, 1, rewrite_options(source, query: query(active: 2)))

    refute Enum.any?(drain_sql(), &String.contains?(&1, "read_parquet"))
    two_rows = check(%{"row_count" => 2})

    for changed <- [%{"hash_xor" => "1"}, %{"hash_sum" => "2"}, %{"row_count" => 1}] do
      assert {:error, :compaction_verification_mismatch} =
               Compactor.rewrite_file(
                 @table,
                 1,
                 rewrite_options(source,
                   query:
                     query(source_check: two_rows, target_check: Map.merge(two_rows, changed)),
                   replace_rewrite: fn _, _, _ -> flunk("unverified rewrite published") end
                 )
               )
    end
  end

  defp rewrite_options(source, overrides \\ []) do
    options(
      Keyword.merge(
        [now: DateTime.add(@time, 3600), source: fn @table, 1, _ -> {:ok, source} end],
        overrides
      )
    )
  end

  defp drain_sql(acc \\ []) do
    receive do
      {:query, sql} -> drain_sql([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
