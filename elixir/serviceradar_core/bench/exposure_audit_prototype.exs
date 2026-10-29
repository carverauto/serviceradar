defmodule ServiceRadar.ExposureAudit.Prototype do
  @moduledoc "Disabled audit experiment, loaded only by its manual Bazel target. No production scheduler references it."
  import ExUnit.Assertions

  alias ServiceRadar.EventWriter.ExposureSnapshotWarehouse, as: Warehouse
  alias ServiceRadar.EventWriter.Processors.ExposureDimensions
  alias ServiceRadar.EventWriter.Processors.ExposureTransitions
  alias ServiceRadar.ExposureAudit.Readiness
  alias ServiceRadar.ExposureAudit.SQL
  alias ServiceRadar.ExposureAudit.State
  alias ServiceRadar.Inventory.ExposureReadiness
  alias ServiceRadar.Inventory.ExposureReconciliationDigest, as: Digest
  alias ServiceRadar.Inventory.ExposureReconciliationWorker, as: Recovery
  alias ServiceRadar.Repo.DirectSession

  @lock_base 320_102_347_440_128

  def measure!(hosts, verify_fixture, repetition) do
    assert hosts == 200
    SQL.verify_digest!()

    expected =
      "SELECT device_ord,control->'source' FROM platform.exposure_reconciliation_checks WHERE device_ord>0"
      |> State.query!()
      |> Map.new(fn [key, value] -> {key, value} end)

    started = now_ms()
    run = State.open!()
    {_, admission_ms} = timed(fn -> resume_admission!(run.id) end)
    {dimension_rows, dimensions_ms} = timed(fn -> dimensions!(run) end)
    {initial, cohorts_ms} = timed(fn -> cohorts!(run, 0, []) end)
    {results, attempts, retry_dimensions_ms, retry_dimension_rows} = retry_proofs!(run, initial)
    dimensions_ms = dimensions_ms + retry_dimensions_ms
    dimension_rows = dimension_rows + retry_dimension_rows
    {_, finish_ms} = timed(fn -> State.finish!(run) end)
    {readiness, readiness_ms} = timed(fn -> ExposureReadiness.status() end)
    {_, cleanup_ms} = timed(fn -> State.cleanup!(run.id) end)
    elapsed = now_ms() - started

    [[proof_rows, proof_bytes]] =
      State.query!(
        "SELECT count(*),COALESCE(sum(pg_column_size(p)),0)::bigint FROM platform.exposure_audit_proofs p WHERE run_id=$1::text::uuid",
        [run.id]
      )

    memory = :erlang.memory(:total)
    assert {:ok, %{ready: true}} = readiness
    assert length(results) == hosts
    for result <- results, do: assert(result.source == Map.fetch!(expected, result.ordinal))
    verify_fixture.(hosts)
    fact_ms = attempts |> Enum.map(& &1.fact_interval) |> Enum.uniq() |> union_ms()
    orchestration_ms = elapsed - dimensions_ms - fact_ms
    # Worker phases overlap. Inclusive time is not a critical-path estimate.
    IO.puts(
      "EXPOSURE_AUDIT_CAPACITY " <>
        Jason.encode!(%{
          repetition: repetition,
          hosts: hosts,
          active_facts: hosts * 2500,
          elapsed_ms: elapsed,
          admission_ms: admission_ms,
          dimensions_ms: dimensions_ms,
          dimension_rows: dimension_rows,
          cohorts_ms: cohorts_ms,
          fact_ms: fact_ms,
          summed_worker_ms: worker_timings(attempts),
          orchestration_ms: orchestration_ms,
          finish_ms: finish_ms,
          readiness_ms: readiness_ms,
          cleanup_ms: cleanup_ms,
          proof_rows: proof_rows,
          proof_bytes: proof_bytes,
          vm_memory_at_completion: memory,
          workers: 2,
          cohort_size: 32,
          matched: length(results)
        })
    )

    assert elapsed <= 900_000, "audit exceeded the unchanged fleet deadline"
    assert dimensions_ms <= 120_000, "dimension component screen failed"

    assert fact_ms <= div(hosts * 2500 * 600_000, 50_000_000),
           "fact component screen failed; no fleet attempt"

    assert orchestration_ms <= div(hosts * 90_000, 20_000),
           "orchestration component screen failed; no fleet attempt"

    run
  end

  def resume_admission!(id) do
    {run, cursor, enumerated} = State.resume!(id)
    if !enumerated, do: enumerate!(run, cursor)
    run
  end

  def enumerate!(run, cursor) do
    source =
      """
      SELECT ordinal FROM (SELECT ordinal FROM platform.device_fleet_ordinals WHERE ordinal>$1
        UNION SELECT device_ord FROM platform.exposure_reconciliation_checks WHERE device_ord>$1) s
      ORDER BY ordinal LIMIT 500
      """
      |> State.query!([cursor])
      |> List.flatten()

    {:ok, stored} = Warehouse.device_ordinals(cursor)

    ordinals =
      (source ++ Enum.map(stored, & &1["device_ord"]))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.take(500)

    next = State.admit!(run, cursor, ordinals)
    if ordinals != [], do: enumerate!(run, next)
  end

  def dimensions!(run, cursor \\ ["", 0], count \\ 0) do
    {rows, proofs} =
      view!(fn reader, _deadline ->
        [[view, checked]] =
          Postgrex.query!(
            reader,
            "SELECT pg_current_snapshot()::text,now() AT TIME ZONE 'utc'",
            []
          ).rows

        rows =
          Postgrex.query!(
            reader,
            """
            SELECT d.kind,d.ordinal,d.transition_seq,d.audit_content_hash,d.payload
            FROM platform.exposure_dimension_state d
            LEFT JOIN platform.exposure_audit_proofs p ON p.run_id=$3::text::uuid AND p.kind=d.kind
              AND p.ordinal=d.ordinal AND p.source_seq=d.transition_seq AND p.source_hash=d.audit_content_hash
            WHERE (d.kind,d.ordinal)>($1,$2) AND (p.run_id IS NULL OR p.checked_at <
              (SELECT max(updated_at) FROM platform.exposure_snapshot_generations WHERE status='complete'))
            ORDER BY d.kind,d.ordinal LIMIT 500
            """,
            cursor ++ [run.id],
            timeout: 30_000
          ).rows

        proofs =
          Enum.flat_map(Enum.group_by(rows, &hd/1), fn {kind, group} ->
            {:ok, stored} = Warehouse.read(kind, Enum.map(group, &Enum.at(&1, 1)))

            Enum.flat_map(group, fn [^kind, key, seq, hash, payload] ->
              case ExposureDimensions.decode([%{data: Jason.encode!(payload)}]) do
                {:ok, [{decoded_kind, ^key, expected}]} ->
                  digest = Warehouse.row_digest(kind, expected)

                  if Atom.to_string(decoded_kind) == kind and expected["transition_seq"] == seq and
                       Map.has_key?(stored, key) and
                       digest == Warehouse.row_digest(kind, stored[key]) do
                    [
                      %{
                        kind: kind,
                        ordinal: key,
                        seq: seq,
                        hash: hash,
                        warehouse_hash: digest,
                        view: view,
                        checked_at: checked
                      }
                    ]
                  else
                    []
                  end

                _ ->
                  []
              end
            end)
          end)

        {rows, proofs}
      end)

    if rows == [] do
      count
    else
      # Failed versions receive no proof; advance by inspected input, not successes.
      State.proofs!(run, proofs)
      [kind, ordinal | _] = List.last(rows)
      dimensions!(run, [kind, ordinal], count + length(rows))
    end
  end

  def compare!(
        run,
        ordinals,
        after_view \\ fn _reader -> :ok end,
        after_comparison \\ fn rows -> rows end
      ) do
    assert length(ordinals) in 1..32
    assert Enum.all?(ordinals, &(is_integer(&1) and &1 in 1..4_294_967_295))

    session_started = now_ms()
    cohort_id = make_ref()

    DirectSession.run(fn session ->
      session_setup_ms = now_ms() - session_started
      # The first query also includes connection checkout/handshake when lazy.
      # Materialize sorted input before evaluating the volatile lock function.
      {locks, lock_ms} =
        timed(fn ->
          rows =
            Postgrex.query!(
              session,
              """
              WITH requested AS MATERIALIZED (
                SELECT ordinal FROM unnest($1::bigint[]) AS requested(ordinal) ORDER BY ordinal
              )
              SELECT ordinal,pg_try_advisory_lock($2::bigint+ordinal) FROM requested ORDER BY ordinal
              """,
              [Enum.sort(ordinals), @lock_base]
            ).rows

          Map.new(rows, fn [ordinal, acquired] -> {ordinal, acquired} end)
        end)

      view_started = now_ms()

      results =
        source_view!(session, fn reader, deadline ->
          [[view, started]] =
            Postgrex.query!(
              reader,
              "SELECT pg_current_snapshot()::text,now() AT TIME ZONE 'utc'",
              []
            ).rows

          view_setup_ms = now_ms() - view_started
          after_view.(reader)
          {coverage, coverage_ms} = timed(fn -> coverage!(reader, run, ordinals) end)
          {lifecycles, lifecycle_ms} = timed(fn -> lifecycle!(reader, ordinals) end)
          fact_started = now_ms()

          {source, source_fact_ms} = timed(fn -> SQL.source!(reader, ordinals) end)
          {stored, warehouse_fact_ms} = timed(fn -> SQL.warehouse_summary!(ordinals) end)

          assert now_ms() < deadline, "cohort source view exceeded sixty seconds"

          Enum.map(ordinals, fn ordinal ->
            {current, drift} = Map.get(source, ordinal, {Digest.empty(), 0})
            warehouse = Map.get(stored, ordinal, Digest.empty())
            {missing, proof_time} = Map.get(coverage, ordinal, {0, nil})

            evidence =
              if proof_time && NaiveDateTime.before?(proof_time, started),
                do: proof_time,
                else: started

            %{
              ordinal: ordinal,
              source: Digest.export(current),
              warehouse: Digest.export(warehouse),
              lock_busy: not locks[ordinal],
              matches:
                locks[ordinal] and missing == 0 and drift == 0 and current == warehouse and
                  lifecycles[ordinal],
              lifecycle_match: lifecycles[ordinal],
              replay_drift: drift,
              missing_proofs: missing,
              evidence_at: evidence,
              fact_started_at: started,
              view: view,
              fact_interval: [fact_started, now_ms()],
              cohort_id: cohort_id,
              worker_ms: %{
                session_start: session_setup_ms,
                locks_including_first_checkout: lock_ms,
                source_view_setup: view_setup_ms,
                coverage: coverage_ms,
                lifecycle: lifecycle_ms,
                source_fact: source_fact_ms,
                warehouse_fact: warehouse_fact_ms
              }
            }
          end)
        end)

      # Keep the session locks through durable result and readiness publication.
      after_comparison.(results)
    end)
  end

  defp coverage!(reader, run, ordinals) do
    rows =
      Postgrex.query!(
        reader,
        coverage_sql(),
        [run.id, ordinals],
        timeout: 30_000
      ).rows

    Map.new(rows, fn [ordinal, missing, time] -> {ordinal, {missing, time}} end)
  end

  # Query plans execute only after the single measurement, outside its intervals.
  def diagnose! do
    [[id]] =
      State.query!(
        "SELECT id::text FROM platform.exposure_audit_runs ORDER BY started_at DESC LIMIT 1"
      )

    ordinals = Enum.to_list(1..32)

    view!(fn reader, _deadline ->
      SQL.explain_source!(reader, ordinals)

      [[plan]] =
        Postgrex.query!(
          reader,
          "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> coverage_sql(),
          [id, ordinals],
          timeout: 30_000
        ).rows

      IO.puts("EXPOSURE_AUDIT_PLAN " <> Jason.encode!(%{query: "coverage", plan: plan}))
    end)
  end

  defp coverage_sql do
    """
    WITH refs AS MATERIALIZED (
      SELECT o.ordinal,a.last_exposure_publication payload FROM platform.device_fleet_ordinals o
      JOIN platform.endpoint_vulnerability_assessments a ON a.device_uid=o.uid WHERE o.ordinal=ANY($2)
      UNION ALL
      SELECT o.ordinal,w.payload FROM platform.device_fleet_ordinals o
      JOIN platform.exposure_fact_watermarks w ON w.device_uid=o.uid WHERE o.ordinal=ANY($2)
    ), keys AS (SELECT r.ordinal device_ord,k.kind,k.key FROM refs r CROSS JOIN LATERAL
      (VALUES ('cve',(payload->>'cve_ord')::bigint),('package',(payload->>'pkgver_ord')::bigint)) k(kind,key))
    SELECT k.device_ord,count(*) FILTER(WHERE d.ordinal IS NULL OR p.run_id IS NULL OR p.checked_at<g.updated_at),min(p.checked_at)
    FROM keys k LEFT JOIN platform.exposure_dimension_state d ON d.kind=k.kind AND d.ordinal=k.key
    LEFT JOIN platform.exposure_audit_proofs p ON p.run_id=$1::text::uuid AND p.kind=d.kind
      AND p.ordinal=d.ordinal AND p.source_seq=d.transition_seq AND p.source_hash=d.audit_content_hash
    LEFT JOIN LATERAL (SELECT updated_at FROM platform.exposure_snapshot_generations
      WHERE status='complete' AND (control->>'scope' IS NULL OR (control->>'scope')::bigint=k.device_ord)
      ORDER BY id DESC LIMIT 1) g ON true
    GROUP BY k.device_ord
    """
  end

  defp lifecycle!(reader, ordinals) do
    rows =
      Postgrex.query!(
        reader,
        "SELECT ordinal,platform.exposure_lifecycle_publication(ordinal) FROM platform.device_fleet_ordinals WHERE ordinal=ANY($1)",
        [ordinals]
      ).rows

    source = Map.new(rows, fn [ordinal, publication] -> {ordinal, publication} end)
    {:ok, stored} = Warehouse.read("lifecycle", ordinals)

    Map.new(ordinals, fn ordinal ->
      matches =
        case Map.fetch(source, ordinal) do
          :error ->
            false

          {:ok, nil} ->
            not Map.has_key?(stored, ordinal)

          {:ok, publication} ->
            case ExposureTransitions.decode([%{data: Jason.encode!(publication)}]) do
              {:ok, [%{row: expected}]} ->
                Map.has_key?(stored, ordinal) and
                  Warehouse.row_digest("lifecycle", expected) ==
                    Warehouse.row_digest("lifecycle", stored[ordinal])

              _ ->
                false
            end
        end

      {ordinal, matches}
    end)
  end

  defp retry_proofs!(run, results) do
    ordinals =
      for result <- results,
          result.missing_proofs > 0 or (result.matches and result.recorded_status == "deferred"),
          do: result.ordinal

    if ordinals == [] do
      {results, results, 0, 0}
    else
      # Coalesce requests across cohorts. No open source view waits for a proof.
      {count, elapsed} = timed(fn -> dimensions!(run) end)

      State.fenced!(run, fn ->
        State.query!(
          "UPDATE platform.exposure_audit_work SET status='pending' WHERE run_id=$1::text::uuid AND device_ord=ANY($2)",
          [run.id, ordinals]
        )
      end)

      retried = cohorts!(run, 0, [])
      latest = Map.new(retried, &{&1.ordinal, &1})
      {Enum.map(results, &Map.get(latest, &1.ordinal, &1)), results ++ retried, elapsed, count}
    end
  end

  defp cohorts!(run, cursor, acc) do
    ordinals = State.next!(run, cursor)

    if ordinals == [] do
      acc
    else
      results =
        ordinals
        |> Enum.chunk_every(32)
        |> Task.async_stream(
          fn cohort ->
            result =
              compare!(run, cohort, fn _ -> :ok end, fn comparisons ->
                {recorded, commit_ms} =
                  timed(fn ->
                    run
                    |> State.record!(Enum.reject(comparisons, & &1.lock_busy))
                    |> Map.new(&{&1["device_ord"], &1["status"]})
                  end)

                {readiness, readiness_ms} = timed(fn -> Readiness.status_many!(cohort) end)
                deferral_started = now_ms()

                for comparison <- comparisons do
                  if !(comparison.matches and readiness[comparison.ordinal].ready) do
                    State.fenced!(run, fn ->
                      State.query!(
                        "UPDATE platform.exposure_audit_work SET status='deferred' WHERE run_id=$1::text::uuid AND device_ord=$2",
                        [run.id, comparison.ordinal]
                      )
                    end)
                  end
                end

                deferral_ms = now_ms() - deferral_started

                Enum.map(comparisons, fn comparison ->
                  comparison
                  |> Map.put(:recorded_status, Map.get(recorded, comparison.ordinal, "busy"))
                  |> Map.update!(:worker_ms, fn timings ->
                    Map.merge(timings, %{
                      result_commit: commit_ms,
                      readiness: readiness_ms,
                      deferral_commit: deferral_ms
                    })
                  end)
                end)
              end)

            for comparison <- result do
              if not comparison.matches and not comparison.lock_busy and
                   comparison.missing_proofs == 0 do
                # Existing recovery acquires its own source lock after ours closes.
                Recovery.perform(%Oban.Job{args: %{"device_ord" => comparison.ordinal}})
              end
            end

            result
          end,
          max_concurrency: 2,
          ordered: false,
          timeout: 90_000
        )
        |> Enum.flat_map(fn {:ok, rows} -> rows end)

      cohorts!(run, List.last(ordinals), results ++ acc)
    end
  end

  def view!(fun), do: DirectSession.run(&source_view!(&1, fun))

  defp source_view!(session, fun) do
    deadline = now_ms() + 60_000

    {:ok, result} =
      Postgrex.transaction(
        session,
        fn reader ->
          Postgrex.query!(
            reader,
            "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY",
            []
          )

          Postgrex.query!(reader, "SET LOCAL statement_timeout='30s'", [])
          result = fun.(reader, deadline)
          assert now_ms() < deadline, "source view deadline exceeded"
          result
        end,
        timeout: 65_000
      )

    result
  end

  defp union_ms(intervals) do
    {total, span} =
      intervals
      |> Enum.sort()
      |> Enum.reduce({0, nil}, fn
        [first, last], {total, nil} ->
          {total, {first, last}}

        [first, last], {total, {start, finish}} when first <= finish ->
          {total, {start, max(last, finish)}}

        [first, last], {total, {start, finish}} ->
          {total + finish - start, {first, last}}
      end)

    case span do
      nil -> total
      {first, last} -> total + last - first
    end
  end

  # A cohort's timings occur on every device result; count each attempt once.
  # These sums include overlapping workers and are not critical-path durations.
  defp worker_timings(attempts) do
    attempts
    |> Enum.uniq_by(& &1.cohort_id)
    |> Enum.reduce(%{}, fn attempt, totals ->
      Map.merge(totals, attempt.worker_ms, fn _phase, left, right -> left + right end)
    end)
  end

  defp timed(fun) do
    started = now_ms()
    value = fun.()
    {value, now_ms() - started}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
