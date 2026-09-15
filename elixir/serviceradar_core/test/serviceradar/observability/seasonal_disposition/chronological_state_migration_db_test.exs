defmodule ServiceRadar.Observability.SeasonalDisposition.ChronologicalStateMigrationDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Observability.SeasonalDisposition.Source
  alias ServiceRadar.Observability.SeasonalDisposition.StateStore
  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.Migrations.CreateChronologicalSeasonalDispositionStates, as: Migration

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20260915000000_create_chronological_seasonal_disposition_states.exs",
                    __DIR__
                  )
  @external_resource @migration_path

  Code.require_file(@migration_path)

  defmodule TemporaryRepo do
    @moduledoc false

    def query(sql, params) do
      sql =
        String.replace(
          sql,
          "platform.seasonal_disposition_chronological_states",
          "pg_temp.migration_chronological_states"
        )

      Repo.query(sql, params)
    end

    def insert_all("seasonal_disposition_chronological_states", rows, opts) do
      Repo.insert_all(
        "migration_chronological_states",
        rows,
        Keyword.put(opts, :prefix, "pg_temp")
      )
    end
  end

  setup do
    Repo.query!("""
    CREATE TEMP TABLE migration_legacy_states (
      source text NOT NULL,
      series_key text NOT NULL,
      dow integer NOT NULL,
      hod integer NOT NULL,
      consecutive_anomalous integer NOT NULL DEFAULT 0,
      last_disposition text,
      last_status text,
      last_score double precision,
      last_evaluated_at timestamp(6) without time zone,
      last_bucket_started_at timestamp(6) without time zone,
      last_bucket_ended_at timestamp(6) without time zone,
      expires_at timestamp(6) without time zone NOT NULL,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL,
      PRIMARY KEY (source, series_key, dow, hod)
    ) ON COMMIT DROP
    """)

    :ok
  end

  test "fresh installs and repeated upgrades leave empty state ready for new writes" do
    run_upgrade()
    run_upgrade()

    assert read_rows("migration_chronological_states") == []
    assert read_rows("migration_legacy_states") == []

    assert {:ok, %{}} =
             StateStore.load_many(%Source{name: "custom_seasonal"}, [{"series/example", 2, 2}],
               repo: TemporaryRepo
             )

    assert {:ok, nil} =
             StateStore.lookup_window_disposition(
               "custom_seasonal",
               "series/example",
               ~U[2030-01-02 02:15:00Z],
               repo: TemporaryRepo
             )

    assert :ok = persist_current("custom_seasonal", 1)

    assert [%{"source" => "custom_seasonal", "consecutive_anomalous" => 1}] =
             read_rows("migration_chronological_states")
  end

  test "resets every legacy source and preserves all window metadata and terminal breach history" do
    assert {:ok, _} = insert_legacy("cpu_seasonal")

    assert {:ok, _} =
             insert_legacy("cpu_seasonal", hod: 3, status: "warming_up", counter: 1)

    assert {:ok, _} =
             insert_legacy("chronological:v1:custom", status: "normal", disposition: "normal")

    before_rows = read_rows("migration_legacy_states")
    run_upgrade()
    expected = Enum.map(before_rows, &Map.put(&1, "consecutive_anomalous", 0))

    assert read_rows("migration_chronological_states") == expected
    assert read_rows("migration_legacy_states") == expected

    assert {:ok, %{"series/example" => state}} =
             StateStore.load_many(%Source{name: "cpu_seasonal"}, [{"series/example", 2, 4}],
               repo: TemporaryRepo
             )

    assert state.consecutive_anomalous == 0
    assert state.bucket_started_at == ~U[2030-01-02 03:00:00.000000Z]
    assert state.previously_confirmed

    assert {:ok, %{source: "chronological:v1:custom", disposition: "normal"}} =
             StateStore.lookup_window_disposition(
               "chronological:v1:custom",
               "series/example",
               ~U[2030-01-02 02:15:00Z],
               repo: TemporaryRepo
             )

    Repo.query!("""
    UPDATE migration_chronological_states
    SET last_status = 'cleared', last_disposition = 'normal'
    WHERE source = 'cpu_seasonal' AND hod = 3
    """)

    assert {:ok, %{"series/example" => cleared_state}} =
             StateStore.load_many(%Source{name: "cpu_seasonal"}, [{"series/example", 2, 4}],
               repo: TemporaryRepo
             )

    refute cleared_state.previously_confirmed
  end

  test "reruns preserve new positive counters and every newer verdict field" do
    assert {:ok, _} = insert_legacy("cpu_seasonal")
    run_upgrade()
    assert :ok = persist_current("cpu_seasonal", 4)
    before_rows = read_rows("migration_chronological_states")

    run_upgrade()
    run_upgrade()

    assert read_rows("migration_chronological_states") == before_rows
    assert [%{"consecutive_anomalous" => 4, "last_score" => 5.5}] = before_rows
    assert [%{"consecutive_anomalous" => 0}] = read_rows("migration_legacy_states")
  end

  test "legacy inserts and conflict updates fail while new state and legacy cleanup remain usable" do
    assert {:ok, _} = insert_legacy("cpu_seasonal")
    run_upgrade()
    assert :ok = persist_current("cpu_seasonal", 3)
    before_rows = read_rows("migration_chronological_states")

    for source <- ["cpu_seasonal", "new_legacy_source"] do
      assert {:error, %Postgrex.Error{postgres: %{pg_code: "55000", message: message}}} =
               insert_legacy(source, query_opts: [mode: :savepoint])

      assert message =~ "upgrade the seasonal disposition worker"
    end

    assert {:error, %Postgrex.Error{postgres: %{pg_code: "55000"}}} =
             Repo.query(
               "UPDATE migration_legacy_states SET consecutive_anomalous = 7",
               [],
               mode: :savepoint
             )

    assert read_rows("migration_chronological_states") == before_rows
    assert %{num_rows: 1} = Repo.query!("DELETE FROM migration_legacy_states")
  end

  test "rollback re-enables legacy writes and a later upgrade retains chronological progress" do
    assert {:ok, _} = insert_legacy("cpu_seasonal")
    run_upgrade()
    assert :ok = persist_current("cpu_seasonal", 2)
    before_rows = read_rows("migration_chronological_states")

    run_statements(Migration.rollback_statements())
    assert {:ok, _} = insert_legacy("cpu_seasonal", counter: 11)
    run_upgrade()

    assert read_rows("migration_chronological_states") == before_rows
    assert [%{"consecutive_anomalous" => 0}] = read_rows("migration_legacy_states")
  end

  defp run_upgrade, do: run_statements(Migration.upgrade_statements())

  defp run_statements(statements) do
    Enum.each(statements, fn sql ->
      sql =
        sql
        |> String.replace("CREATE TABLE IF NOT EXISTS", "CREATE TEMP TABLE IF NOT EXISTS")
        |> String.replace(
          "platform.seasonal_disposition_chronological_states",
          "pg_temp.migration_chronological_states"
        )
        |> String.replace(
          "platform.seasonal_disposition_states",
          "pg_temp.migration_legacy_states"
        )
        |> String.replace(
          "platform.reject_legacy_seasonal_disposition_writes",
          "pg_temp.reject_legacy_seasonal_disposition_writes"
        )

      Repo.query!(sql)
    end)
  end

  defp insert_legacy(source, opts \\ []) do
    hod = Keyword.get(opts, :hod, 2)
    started_at = NaiveDateTime.add(~N[2030-01-02 00:00:00], hod * 3_600)
    ended_at = NaiveDateTime.add(started_at, 3_600)

    Repo.query(
      """
      INSERT INTO migration_legacy_states (
        source, series_key, dow, hod, consecutive_anomalous,
        last_disposition, last_status, last_score, last_evaluated_at,
        last_bucket_started_at, last_bucket_ended_at, expires_at, inserted_at, updated_at
      ) VALUES ($1, 'series/example', 2, $2, $3, $4, $5, 3.5, $7, $6, $7,
                '2032-01-01', '2030-01-01', $7)
      ON CONFLICT (source, series_key, dow, hod) DO UPDATE SET
        consecutive_anomalous = EXCLUDED.consecutive_anomalous,
        last_disposition = EXCLUDED.last_disposition,
        last_status = EXCLUDED.last_status,
        last_score = EXCLUDED.last_score,
        last_evaluated_at = EXCLUDED.last_evaluated_at,
        last_bucket_started_at = EXCLUDED.last_bucket_started_at,
        last_bucket_ended_at = EXCLUDED.last_bucket_ended_at,
        expires_at = EXCLUDED.expires_at,
        updated_at = EXCLUDED.updated_at
      """,
      [
        source,
        hod,
        Keyword.get(opts, :counter, 9),
        Keyword.get(opts, :disposition, "seasonal_breach"),
        Keyword.get(opts, :status, "breach"),
        started_at,
        ended_at
      ],
      Keyword.get(opts, :query_opts, [])
    )
  end

  defp persist_current(source, counter) do
    StateStore.persist_many(
      %Source{name: source},
      [
        %{
          key: {"series/example", 2, 2},
          consecutive_anomalous: counter,
          disposition: "seasonal_drift",
          status: "breach",
          score: 5.5,
          evaluated_at: ~U[2030-01-09 03:05:00Z],
          bucket_started_at: ~U[2030-01-09 02:00:00Z],
          bucket_ended_at: ~U[2030-01-09 03:00:00Z]
        }
      ],
      repo: TemporaryRepo,
      now: ~U[2030-01-09 03:05:00Z]
    )
  end

  defp read_rows(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT to_jsonb(state) FROM #{table} state ORDER BY source, series_key, dow, hod"
      )

    Enum.map(rows, fn [row] -> row end)
  end
end
