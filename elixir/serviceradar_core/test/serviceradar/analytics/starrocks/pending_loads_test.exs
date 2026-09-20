defmodule ServiceRadar.Analytics.StarRocks.PendingLoadsTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.PendingLoads
  alias ServiceRadar.Analytics.StarRocks.PendingLoads.Record
  alias ServiceRadar.Analytics.StarRocks.Rows
  alias ServiceRadar.Analytics.StarRocks.StreamLoad
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  import Ecto.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    original = Application.get_env(:serviceradar_core, StarRocks, [])

    on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, original) end)

    {:ok, bin_id} = Ecto.UUID.dump("550e8400-e29b-41d4-a716-446655440000")

    rows = [
      %{
        id: bin_id,
        time: ~U[2026-09-20 10:00:00Z],
        class_uid: 4001,
        category_uid: 4,
        type_uid: 400_101,
        activity_id: 1,
        severity_id: 3,
        severity: "High",
        message: "synthetic threshold violation",
        status_id: 1
      }
    ]

    {:ok, rows: rows}
  end

  test "persist_or_enqueue loads directly when the warehouse write succeeds", %{rows: rows} do
    with_cutover([:events])

    persist = fn _table, _rows, opts ->
      {:ok, %{label: opts[:label], loaded: 1}}
    end

    assert {:ok, %{loaded: 1}} = PendingLoads.persist_or_enqueue(:events, rows, persist: persist)
    assert Repo.aggregate(Record, :count) == 0
  end

  test "persist_or_enqueue quarantines the batch when the cutover load fails", %{rows: rows} do
    with_cutover([:events])

    persist = fn _table, _rows, _opts -> {:error, {:http_status, 503, "sr-test"}} end

    assert {:ok, :enqueued} = PendingLoads.persist_or_enqueue(:events, rows, persist: persist)

    encoded = Rows.encode(:events, rows)
    label = StreamLoad.load_label("events", encoded)
    record = Repo.get_by!(Record, label: label)

    assert record.dataset == "events"
    assert record.table_name == "events"
    assert record.payload["rows"] == Jason.decode!(Jason.encode!(encoded))
    assert record.attempts == 0
    assert_next_retry_in(record.next_retry_at, 60, 15)
  end

  test "persist_or_enqueue stays best-effort while events are not cut over", %{rows: rows} do
    with_cutover([])

    # A crash inside the shadow write is swallowed to {:ok, :disabled} by the
    # best-effort path, so nothing reaches the outbox either.
    persist = fn _table, _rows, _opts -> raise "stream load unavailable" end

    assert {:ok, :disabled} = PendingLoads.persist_or_enqueue(:events, rows, persist: persist)
    assert Repo.aggregate(Record, :count) == 0
  end

  test "persist_or_enqueue quarantines the batch when the load crashes", %{rows: rows} do
    with_cutover([:events])

    persist = fn _table, _rows, _opts -> raise "stream load unavailable" end

    assert {:ok, :enqueued} = PendingLoads.persist_or_enqueue(:events, rows, persist: persist)
    assert Repo.aggregate(Record, :count) == 1
  end

  test "drain_due replays due batches with their stored label", %{rows: rows} do
    with_cutover([:events])

    failing = fn _table, _rows, _opts -> {:error, {:http_status, 503, "sr-test"}} end
    assert {:ok, :enqueued} = PendingLoads.persist_or_enqueue(:events, rows, persist: failing)

    caller = self()

    replay =
      fn table, replay_rows, opts ->
        send(caller, {:persisted, table, replay_rows, opts})
        {:ok, %{label: opts[:label], loaded: length(replay_rows)}}
      end

    # The enqueue schedules the first retry a minute out; make it due now.
    Repo.update_all(Record,
      set: [next_retry_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -1, :second)]
    )

    assert {:ok, %{drained: 1, quarantined: 0, deferred: 0}} =
             PendingLoads.drain_due(persist: replay)

    encoded = Rows.encode(:events, rows)
    label = StreamLoad.load_label("events", encoded)

    assert_received {:persisted, "events", ^encoded, opts}
    assert opts[:label] == label
    assert Repo.aggregate(Record, :count) == 0
  end

  test "drain_due defers failed batches with backoff", %{rows: rows} do
    with_cutover([:events])

    failing = fn _table, _rows, _opts -> {:error, {:http_status, 503, "sr-test"}} end
    assert {:ok, :enqueued} = PendingLoads.persist_or_enqueue(:events, rows, persist: failing)

    Repo.update_all(Record,
      set: [next_retry_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -1, :second)]
    )

    assert {:ok, %{drained: 0, quarantined: 0, deferred: 1}} =
             PendingLoads.drain_due(persist: failing)

    record = Repo.one!(Record)
    assert record.attempts == 1
    assert_next_retry_in(record.next_retry_at, 300, 30)
  end

  test "drain_due skips batches that are not due yet", %{rows: rows} do
    with_cutover([:events])

    failing = fn _table, _rows, _opts -> {:error, {:http_status, 503, "sr-test"}} end
    assert {:ok, :enqueued} = PendingLoads.persist_or_enqueue(:events, rows, persist: failing)

    Repo.update_all(Record,
      set: [next_retry_at: NaiveDateTime.add(NaiveDateTime.utc_now(), 3_600, :second)]
    )

    exploding = fn _table, _rows, _opts -> raise "must not be called" end

    assert {:ok, %{drained: 0, quarantined: 0, deferred: 0}} =
             PendingLoads.drain_due(persist: exploding)

    assert Repo.aggregate(Record, :count) == 1
  end

  test "drain_due drops batches the warehouse quarantines on replay", %{rows: rows} do
    with_cutover([:events])

    failing = fn _table, _rows, _opts -> {:error, {:http_status, 503, "sr-test"}} end
    assert {:ok, :enqueued} = PendingLoads.persist_or_enqueue(:events, rows, persist: failing)

    Repo.update_all(Record,
      set: [next_retry_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -1, :second)]
    )

    filtered = fn _table, _rows, opts ->
      {:quarantine, {:filtered_rows, 1, opts[:label]}}
    end

    assert {:ok, %{drained: 0, quarantined: 1, deferred: 0}} =
             PendingLoads.drain_due(persist: filtered)

    assert Repo.aggregate(Record, :count) == 0
  end

  test "persist_or_enqueue reports instead of raising when quarantining fails", %{rows: rows} do
    with_cutover([:events])

    # A non-map row makes the row encoder raise, so the load fails AND the
    # quarantine that would store it fails on the same input. The producing
    # worker self-schedules, so this must answer rather than escape.
    assert {:error, {:quarantine_failed, {:crashed, _}}} =
             PendingLoads.persist_or_enqueue(:events, rows ++ [:not_a_row])

    assert Repo.aggregate(Record, :count) == 0
  end

  test "drain_due replays the oldest quarantined batch first" do
    insert_pending!("sr-newer", 10)
    insert_pending!("sr-older", 600)

    caller = self()

    replay = fn _table, _rows, opts ->
      send(caller, {:replayed, opts[:label]})
      {:ok, %{label: opts[:label], loaded: 1}}
    end

    assert {:ok, %{drained: 2, deferred: 0}} = PendingLoads.drain_due(persist: replay)

    assert_received {:replayed, first}
    assert_received {:replayed, second}
    assert first == "sr-older"
    assert second == "sr-newer"
  end

  test "drain_due claims the rows it selects so an overlapping drain skips them" do
    insert_pending!("sr-claimed", 60)

    caller = self()

    overlapping = fn _table, _rows, opts ->
      {:ok, inner} =
        PendingLoads.drain_due(
          persist: fn _table, _rows, _opts ->
            send(caller, :replayed_twice)
            {:ok, %{loaded: 1}}
          end
        )

      send(caller, {:inner, inner})

      {:ok, %{label: opts[:label], loaded: 1}}
    end

    assert {:ok, %{drained: 1, skipped: 0}} = PendingLoads.drain_due(persist: overlapping)

    assert_received {:inner, %{drained: 0, quarantined: 0, deferred: 0, dead_lettered: 0}}
    refute_received :replayed_twice
    assert Repo.aggregate(Record, :count) == 0
  end

  test "drain_due replays at most ten batches per run" do
    for n <- 1..11, do: insert_pending!("sr-bounded-#{n}", 100 - n)

    replay = fn _table, _rows, opts -> {:ok, %{label: opts[:label], loaded: 1}} end

    assert {:ok, %{drained: 10, quarantined: 0, deferred: 0, dead_lettered: 0}} =
             PendingLoads.drain_due(persist: replay)

    assert Repo.aggregate(Record, :count) == 1
  end

  test "drain_due dead-letters only once the replay budget is exhausted" do
    nearly = insert_pending!("sr-nearly-exhausted", 120)
    exhausted = insert_pending!("sr-exhausted", 60)

    set_attempts!(nearly, 23)
    set_attempts!(exhausted, 24)

    failing = fn _table, _rows, _opts -> {:error, {:load_status, "Fail", "sr-test"}} end

    assert {:ok, %{drained: 0, quarantined: 0, deferred: 1, dead_lettered: 1}} =
             PendingLoads.drain_due(persist: failing)

    assert [%Record{label: ^nearly, attempts: 24}] = Repo.all(Record)
  end

  test "enqueueing the same batch twice keeps a single row", %{rows: rows} do
    with_cutover([:events])

    failing = fn _table, _rows, _opts -> {:error, {:http_status, 503, "sr-test"}} end

    assert {:ok, :enqueued} = PendingLoads.persist_or_enqueue(:events, rows, persist: failing)
    assert {:ok, :enqueued} = PendingLoads.persist_or_enqueue(:events, rows, persist: failing)
    assert Repo.aggregate(Record, :count) == 1
  end

  defp with_cutover(datasets) do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:enabled, true)
      |> Keyword.put(:shadow_datasets, [:events])
      |> Keyword.put(:cutover_datasets, datasets)
    )
  end

  defp insert_pending!(label, inserted_seconds_ago) do
    now = NaiveDateTime.utc_now()

    %Record{}
    |> Ecto.Changeset.change(%{
      dataset: "events",
      table_name: "events",
      label: label,
      payload: %{"rows" => [%{"id" => label}]},
      attempts: 0,
      next_retry_at: NaiveDateTime.add(now, -1, :second)
    })
    |> Repo.insert!()

    # `timestamps()` resolves to whole seconds, so the drain's oldest-first
    # order is only observable with inserted_at set apart explicitly.
    Repo.update_all(from(r in Record, where: r.label == ^label),
      set: [inserted_at: NaiveDateTime.add(now, -inserted_seconds_ago, :second)]
    )

    label
  end

  defp set_attempts!(label, attempts) do
    {1, _} =
      Repo.update_all(from(r in Record, where: r.label == ^label), set: [attempts: attempts])
    :ok
  end

  defp assert_next_retry_in(next_retry_at, expected_seconds, tolerance_seconds) do
    diff = NaiveDateTime.diff(next_retry_at, NaiveDateTime.utc_now(), :second)
    assert diff >= expected_seconds - tolerance_seconds
    assert diff <= expected_seconds + tolerance_seconds
  end
end
