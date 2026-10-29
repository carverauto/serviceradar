defmodule ServiceRadar.ExposureAudit.Migration do
  @moduledoc "Scratch-only migration; deliberately outside the production migration discovery path."
  use Ecto.Migration

  def up do
    execute(
      "ALTER TABLE platform.exposure_dimension_state ADD COLUMN audit_content_hash bytea GENERATED ALWAYS AS (sha256(jsonb_send(payload))) STORED"
    )

    execute(
      "CREATE TABLE platform.exposure_audit_epoch (id boolean PRIMARY KEY DEFAULT true CHECK(id), fence bigint NOT NULL)"
    )

    execute("INSERT INTO platform.exposure_audit_epoch VALUES (true,1)")

    execute("""
    CREATE TABLE platform.exposure_audit_runs (
      id uuid PRIMARY KEY, fence bigint NOT NULL, format_version integer NOT NULL DEFAULT 1, status text NOT NULL,
      started_at timestamp NOT NULL DEFAULT (clock_timestamp() AT TIME ZONE 'utc'),
      expires_at timestamp NOT NULL DEFAULT (clock_timestamp() AT TIME ZONE 'utc' + interval '900 seconds'),
      cursor bigint NOT NULL DEFAULT 0, enumerated boolean NOT NULL DEFAULT false)
    """)

    execute("""
    CREATE TABLE platform.exposure_audit_proofs (
      run_id uuid NOT NULL REFERENCES platform.exposure_audit_runs(id) ON DELETE CASCADE,
      kind text NOT NULL, ordinal bigint NOT NULL, source_seq bigint NOT NULL,
      source_hash bytea NOT NULL, warehouse_hash text NOT NULL, checked_at timestamp NOT NULL,
      source_view text NOT NULL,
      PRIMARY KEY(run_id,kind,ordinal,source_seq,source_hash))
    """)

    execute("""
    CREATE TABLE platform.exposure_audit_work (
      run_id uuid NOT NULL REFERENCES platform.exposure_audit_runs(id) ON DELETE CASCADE,
      device_ord bigint NOT NULL, status text NOT NULL DEFAULT 'pending', evidence_at timestamp,
      result jsonb NOT NULL DEFAULT '{}', PRIMARY KEY(run_id,device_ord))
    """)

    execute(
      "CREATE INDEX exposure_audit_pending ON platform.exposure_audit_work(run_id,status,device_ord)"
    )
  end

  def down do
    execute(
      "DROP TABLE platform.exposure_audit_work, platform.exposure_audit_proofs, platform.exposure_audit_runs, platform.exposure_audit_epoch"
    )

    execute("ALTER TABLE platform.exposure_dimension_state DROP COLUMN audit_content_hash")
  end
end

defmodule ServiceRadar.ExposureAudit.State do
  @moduledoc "Durable admission and recovery fencing for the disabled scratch prototype."
  import ExUnit.Assertions

  alias ServiceRadar.ExposureAudit.Migration
  alias ServiceRadar.Repo

  @version 20_261_029_013_300

  def install! do
    assert System.get_env("EXPOSURE_AUDIT_PROTOTYPE") == "1"
    [[database]] = query!("SELECT current_database()")

    assert Regex.match?(~r/^sr_core_test_[a-z0-9_]+$/, database),
           "audit prototype requires a canonical disposable clone"

    assert [[nil]] = query!("SELECT to_regclass('platform.exposure_audit_runs')")
    :ok = Ecto.Migrator.up(Repo, @version, Migration, log: false)
  end

  def uninstall! do
    :ok = Ecto.Migrator.down(Repo, @version, Migration, log: false)
    assert [[nil]] = query!("SELECT to_regclass('platform.exposure_audit_runs')")
  end

  def open! do
    id = Ecto.UUID.generate()

    [[fence, started]] =
      query!(
        """
        INSERT INTO platform.exposure_audit_runs(id,fence,status)
        SELECT $1::text::uuid,fence,'running' FROM platform.exposure_audit_epoch
        RETURNING fence,started_at
        """,
        [id]
      )

    %{id: id, fence: fence, started: started}
  end

  def resume!(id) do
    [[fence, started, cursor, enumerated]] =
      query!(
        """
        SELECT fence,started_at,cursor,enumerated FROM platform.exposure_audit_runs
        WHERE id=$1::text::uuid AND format_version=1
        """,
        [id]
      )

    run = %{id: id, fence: fence, started: started}
    fenced!(run, fn -> :ok end)
    {run, cursor, enumerated}
  end

  def fenced!(run, fun) do
    {:ok, result} =
      Repo.transaction(
        fn ->
          assert [[run.fence]] ==
                   query!("SELECT fence FROM platform.exposure_audit_epoch FOR SHARE"),
                 "audit recovery fence changed"

          assert [[true]] ==
                   query!(
                     """
                     SELECT status='running' AND fence=$2 AND expires_at>clock_timestamp() AT TIME ZONE 'utc'
                     FROM platform.exposure_audit_runs WHERE id=$1::text::uuid FOR UPDATE
                     """,
                     [run.id, run.fence]
                   ),
                 "audit run expired or closed"

          result = fun.()

          assert [[true]] ==
                   query!(
                     "SELECT expires_at>clock_timestamp() AT TIME ZONE 'utc' FROM platform.exposure_audit_runs WHERE id=$1::text::uuid",
                     [run.id]
                   )

          result
        end,
        timeout: 60_000
      )

    result
  end

  def invalidate! do
    {:ok, fence} =
      Repo.transaction(fn ->
        [[fence]] =
          query!("UPDATE platform.exposure_audit_epoch SET fence=fence+1 RETURNING fence")

        query!(
          "UPDATE platform.exposure_audit_runs SET status='invalidated' WHERE status='running'"
        )

        fence
      end)

    fence
  end

  def admit!(run, expected_cursor, ordinals) do
    assert length(ordinals) <= 500
    assert ordinals == Enum.sort(Enum.uniq(ordinals))
    assert Enum.all?(ordinals, &(&1 > expected_cursor and &1 <= 4_294_967_295))

    fenced!(run, fn ->
      [[^expected_cursor]] =
        query!("SELECT cursor FROM platform.exposure_audit_runs WHERE id=$1::text::uuid", [run.id])

      query!(
        """
        INSERT INTO platform.exposure_audit_work(run_id,device_ord)
        SELECT $1::text::uuid,unnest($2::bigint[]) ON CONFLICT DO NOTHING
        """,
        [run.id, ordinals]
      )

      next = List.last(ordinals) || expected_cursor

      query!(
        "UPDATE platform.exposure_audit_runs SET cursor=$2,enumerated=$3 WHERE id=$1::text::uuid",
        [
          run.id,
          next,
          ordinals == []
        ]
      )

      next
    end)
  end

  def next!(run, cursor) do
    """
    SELECT device_ord FROM platform.exposure_audit_work
    WHERE run_id=$1::text::uuid AND device_ord>$2 AND status='pending'
    ORDER BY device_ord LIMIT 64
    """
    |> query!([run.id, cursor])
    |> List.flatten()
  end

  def proofs!(run, rows) do
    assert length(rows) <= 500

    fenced!(run, fn ->
      fields = [:kind, :ordinal, :seq, :hash, :warehouse_hash, :checked_at, :view]
      arrays = Enum.map(fields, fn field -> Enum.map(rows, &Map.fetch!(&1, field)) end)

      query!(
        """
        INSERT INTO platform.exposure_audit_proofs
          (run_id,kind,ordinal,source_seq,source_hash,warehouse_hash,checked_at,source_view)
        SELECT $1::text::uuid,* FROM unnest($2::text[],$3::bigint[],$4::bigint[],$5::bytea[],
          $6::text[],$7::timestamp[],$8::text[])
        ON CONFLICT(run_id,kind,ordinal,source_seq,source_hash) DO UPDATE
        SET checked_at=EXCLUDED.checked_at,source_view=EXCLUDED.source_view,warehouse_hash=EXCLUDED.warehouse_hash
        """,
        [run.id | arrays]
      )
    end)
  end

  def record!(run, results) do
    assert length(results) <= 32

    fenced!(run, fn ->
      # Serialize the final generation check with completion of covering snapshots.
      query!("LOCK TABLE platform.exposure_snapshot_generations IN SHARE MODE")

      generations =
        """
        SELECT ordinal,COALESCE(g.id,0),g.updated_at FROM unnest($1::bigint[]) ordinal
        LEFT JOIN LATERAL (SELECT id,updated_at FROM platform.exposure_snapshot_generations
          WHERE status='complete' AND (control->>'scope' IS NULL OR (control->>'scope')::bigint=ordinal)
          ORDER BY id DESC LIMIT 1) g ON true
        """
        |> query!([Enum.map(results, & &1.ordinal)])
        |> Map.new(fn [id, g, t] -> {id, {g, t}} end)

      rows =
        Enum.map(results, fn result ->
          {covering, time} = Map.fetch!(generations, result.ordinal)
          fresh = not is_nil(time) and NaiveDateTime.compare(result.evidence_at, time) != :lt
          status = if result.matches and fresh, do: "matched", else: "deferred"

          control = %{
            "source" => result.source,
            "warehouse" => result.warehouse,
            "started_at" => NaiveDateTime.to_iso8601(result.evidence_at),
            "fact_started_at" => NaiveDateTime.to_iso8601(result.fact_started_at),
            "snapshot" => result.view,
            "audit_run" => run.id,
            "covering_generation" => covering
          }

          %{
            "device_ord" => result.ordinal,
            "status" => status,
            "control" => control,
            "evidence_at" => NaiveDateTime.to_iso8601(result.evidence_at)
          }
        end)

      query!(
        """
        WITH input AS (SELECT * FROM jsonb_to_recordset($1) AS r(device_ord bigint,status text,control jsonb,evidence_at timestamp))
        INSERT INTO platform.exposure_reconciliation_checks(device_ord,status,control,checked_at,inserted_at,updated_at)
        SELECT device_ord,status,control,evidence_at,now(),now() FROM input
        ON CONFLICT(device_ord) DO UPDATE
        SET status=EXCLUDED.status,control=exposure_reconciliation_checks.control || EXCLUDED.control,
          checked_at=EXCLUDED.checked_at,updated_at=now()
        """,
        [rows]
      )

      query!(
        """
        UPDATE platform.exposure_audit_work w SET status=r.status,result=r.control,evidence_at=r.evidence_at
        FROM jsonb_to_recordset($2) AS r(device_ord bigint,status text,control jsonb,evidence_at timestamp)
        WHERE w.run_id=$1::text::uuid AND w.device_ord=r.device_ord
        """,
        [run.id, rows]
      )

      rows
    end)
  end

  def finish!(run) do
    fenced!(run, fn ->
      assert [[true, 0]] =
               query!(
                 """
                 SELECT enumerated,(SELECT count(*) FROM platform.exposure_audit_work
                   WHERE run_id=r.id AND status<>'matched')
                 FROM platform.exposure_audit_runs r WHERE id=$1::text::uuid
                 """,
                 [run.id]
               )

      query!(
        """
        INSERT INTO platform.exposure_reconciliation_checks(device_ord,status,control,checked_at,inserted_at,updated_at)
        VALUES (0,'matched',jsonb_build_object('started_at',$1::text),now(),now(),now())
        ON CONFLICT(device_ord) DO UPDATE SET status='matched',control=EXCLUDED.control,checked_at=now(),updated_at=now()
        """,
        [NaiveDateTime.to_iso8601(run.started)]
      )

      query!(
        "UPDATE platform.exposure_audit_runs SET status='complete' WHERE id=$1::text::uuid",
        [run.id]
      )
    end)
  end

  def cleanup!(keep) do
    # Child deletion is paged so deleting a run cannot cascade an unbounded set.
    # The caller retains its run and the most recently completed proof set.
    for table <- ~w(exposure_audit_proofs exposure_audit_work exposure_audit_runs) do
      cleanup_page!(table, keep)
    end
  end

  defp cleanup_page!(table, keep) do
    join = if table == "exposure_audit_runs", do: "p.id", else: "p.run_id"

    rows =
      query!(
        """
        DELETE FROM platform.#{table} WHERE ctid IN (
          SELECT p.ctid FROM platform.#{table} p JOIN platform.exposure_audit_runs r ON r.id=#{join}
          WHERE r.id<>$1::text::uuid
            AND r.id IS DISTINCT FROM (SELECT id FROM platform.exposure_audit_runs
              WHERE status='complete' ORDER BY started_at DESC,id DESC LIMIT 1)
            AND (r.status<>'running' OR r.expires_at<clock_timestamp() AT TIME ZONE 'utc')
          LIMIT 500) RETURNING 1
        """,
        [keep]
      )

    if rows != [], do: cleanup_page!(table, keep)
  end

  def query!(sql, params \\ []), do: Repo.query!(sql, params, timeout: 30_000).rows
end
