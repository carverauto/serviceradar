defmodule ServiceRadar.ExposureAudit.Receipts do
  @moduledoc "Content-bound source validation for the disabled scratch audit; never warehouse evidence."
  import ExUnit.Assertions

  alias ServiceRadar.EventWriter.Processors.ExposureTransitions
  alias ServiceRadar.ExposureAudit.State
  alias ServiceRadar.Inventory.ExposureReconciliationDigest, as: Digest

  # Bump for changes to decoder, v1 digest or PostgreSQL fingerprint semantics.
  @revision 1
  @zero "00000000-0000-0000-0000-000000000000"

  def revision, do: @revision

  def prepare!(run) do
    [[cursor, upper, complete]] =
      State.query!(
        "SELECT receipt_cursor::text,receipt_upper::text,receipts_enumerated FROM platform.exposure_audit_runs WHERE id=$1::text::uuid",
        [run.id]
      )

    prepared = if complete, do: 0, else: scan!(run, cursor, upper, nil)

    [[retry_upper]] =
      State.query!(
        "SELECT COALESCE((SELECT assessment_id FROM platform.exposure_audit_receipt_work WHERE run_id=$1::text::uuid ORDER BY assessment_id DESC LIMIT 1),$2::text::uuid)::text",
        [run.id, @zero]
      )

    prepared + retry!(run, @zero, retry_upper)
  end

  # A miss behind the durable admission cursor is revisited in a new source
  # view. Its device stays deferred until a later comparison succeeds.
  def prepare_devices!(run, ordinals) do
    assert length(ordinals) <= 32
    assert Enum.all?(ordinals, &(&1 in 1..4_294_967_295))

    [[upper]] =
      State.query!(
        """
        SELECT COALESCE((SELECT a.id FROM platform.endpoint_vulnerability_assessments a
          JOIN platform.device_fleet_ordinals o ON o.uid=a.device_uid
          WHERE o.ordinal=ANY($1) ORDER BY a.id DESC LIMIT 1),$2::text::uuid)::text
        """,
        [ordinals, @zero]
      )

    scan!(run, @zero, upper, ordinals)
  end

  defp scan!(run, cursor, upper, ordinals) do
    rows =
      State.query!(
        """
        WITH page AS MATERIALIZED (
          SELECT a.id,a.audit_publication_hash,a.last_exposure_publication
          FROM platform.endpoint_vulnerability_assessments a
          WHERE a.id>$1::text::uuid AND a.id<=$2::text::uuid
            AND ($3::bigint[] IS NULL OR a.device_uid IN
              (SELECT uid FROM platform.device_fleet_ordinals WHERE ordinal=ANY($3)))
          ORDER BY a.id LIMIT 500)
        SELECT a.id::text,a.audit_publication_hash,
          CASE WHEN r.assessment_id IS NULL THEN a.last_exposure_publication END,r.assessment_id IS NOT NULL
        FROM page a LEFT JOIN platform.exposure_audit_receipts r
          ON r.assessment_id=a.id AND r.payload_hash=a.audit_publication_hash AND r.validator_revision=$4
        ORDER BY a.id
        """,
        [cursor, upper, ordinals, @revision]
      )

    next = if rows == [], do: cursor, else: rows |> List.last() |> hd()
    progress = if is_nil(ordinals), do: {cursor, next, rows == []}
    candidates = for [id, hash, payload, false] <- rows, do: [id, hash, payload]
    count = persist!(run, validate(candidates), progress)
    if rows == [], do: count, else: count + scan!(run, next, upper, ordinals)
  end

  defp retry!(run, cursor, upper) do
    rows =
      State.query!(
        """
        SELECT w.assessment_id::text,a.audit_publication_hash,a.last_exposure_publication
        FROM platform.exposure_audit_receipt_work w
        LEFT JOIN platform.endpoint_vulnerability_assessments a ON a.id=w.assessment_id
        WHERE w.run_id=$1::text::uuid AND w.assessment_id>$2::text::uuid AND w.assessment_id<=$3::text::uuid
        ORDER BY w.assessment_id LIMIT 500
        """,
        [run.id, cursor, upper]
      )

    if rows == [] do
      0
    else
      count = persist!(run, validate(rows))
      count + retry!(run, rows |> List.last() |> hd(), upper)
    end
  end

  # These are page operations, also used by the concurrency controls. Decoding
  # finishes before any source/receipt lock is acquired; at most two workers.
  def validate(rows) do
    assert length(rows) <= 500

    rows
    |> Enum.chunk_every(250)
    |> Task.async_stream(&Enum.map(&1, fn [id, hash, payload] -> receipt(id, hash, payload) end),
      max_concurrency: 2,
      timeout: 30_000
    )
    |> Enum.flat_map(fn {:ok, receipts} -> receipts end)
  end

  defp receipt(id, hash, payload) do
    {valid, state, digest} =
      case ExposureTransitions.decode([%{data: Jason.encode!(payload)}]) do
        {:ok, [%{kind: :fact, fact: fact}]} ->
          summary = Digest.add(Digest.empty(), fact)
          digest = if fact["state"] == 1, do: <<summary.sum::unsigned-256>>
          {true, fact["state"], digest}

        _ ->
          {false, nil, nil}
      end

    %{
      id: id,
      hash: hash,
      valid: valid,
      state: state,
      digest: digest,
      cve: reference(payload, "cve_ord"),
      package: reference(payload, "pkg_ord"),
      version: reference(payload, "pkgver_ord")
    }
  end

  defp reference(payload, key) when is_map(payload) do
    value = payload[key]
    if is_integer(value) and value in 1..9_223_372_036_854_775_807, do: value
  end

  defp reference(_, _), do: nil

  def persist!(run, receipts, progress \\ nil) do
    assert length(receipts) <= 500

    State.fenced!(run, fn ->
      ids = Enum.map(receipts, & &1.id)

      # Lock source before receipt, without waiting for a writer. Recheck the
      # complete binding under that lock, so a paused old preparer cannot win.
      locked =
        """
        SELECT id::text,audit_publication_hash FROM platform.endpoint_vulnerability_assessments
        WHERE id=ANY($1::text[]::uuid[]) ORDER BY id FOR SHARE SKIP LOCKED
        """
        |> State.query!([ids])
        |> Map.new(fn [id, hash] -> {id, hash} end)

      accepted = Enum.filter(receipts, &(not is_nil(&1.hash) and locked[&1.id] == &1.hash))
      upsert!(accepted)

      State.query!(
        """
        INSERT INTO platform.exposure_audit_receipt_work(run_id,assessment_id)
        SELECT $1::text::uuid,unnest($2::text[]::uuid[]) ON CONFLICT DO NOTHING
        """,
        [run.id, ids -- Enum.map(accepted, & &1.id)]
      )

      State.query!(
        """
        DELETE FROM platform.exposure_audit_receipt_work w WHERE run_id=$1::text::uuid
          AND (assessment_id=ANY($2::text[]::uuid[]) OR
            (assessment_id=ANY($3::text[]::uuid[]) AND NOT EXISTS
              (SELECT 1 FROM platform.endpoint_vulnerability_assessments a WHERE a.id=w.assessment_id)))
        """,
        [run.id, Enum.map(accepted, & &1.id), ids]
      )

      advance!(run, progress)
      length(accepted)
    end)
  end

  defp advance!(_run, nil), do: :ok

  defp advance!(run, {cursor, next, complete}) do
    assert [[next]] ==
             State.query!(
               """
               UPDATE platform.exposure_audit_runs SET receipt_cursor=$3::text::uuid,receipts_enumerated=$4
               WHERE id=$1::text::uuid AND receipt_cursor=$2::text::uuid AND NOT receipts_enumerated
               RETURNING receipt_cursor::text
               """,
               [run.id, cursor, next, complete]
             )
  end

  defp upsert!([]), do: :ok

  defp upsert!(receipts) do
    fields = [:id, :hash, :valid, :state, :digest, :cve, :package, :version]
    arrays = Enum.map(fields, fn field -> Enum.map(receipts, &Map.fetch!(&1, field)) end)

    State.query!(
      """
      INSERT INTO platform.exposure_audit_receipts
        (assessment_id,payload_hash,valid_after_image,replay_state,replay_digest,cve_ord,pkg_ord,pkgver_ord,validator_revision)
      SELECT id::uuid,hash,valid,state,digest,cve,package,version,$9 FROM
        unnest($1::text[],$2::bytea[],$3::boolean[],$4::smallint[],$5::bytea[],
          $6::bigint[],$7::bigint[],$8::bigint[]) r(id,hash,valid,state,digest,cve,package,version)
      ON CONFLICT(assessment_id) DO UPDATE SET payload_hash=EXCLUDED.payload_hash,
        validator_revision=EXCLUDED.validator_revision,valid_after_image=EXCLUDED.valid_after_image,
        replay_state=EXCLUDED.replay_state,replay_digest=EXCLUDED.replay_digest,
        cve_ord=EXCLUDED.cve_ord,pkg_ord=EXCLUDED.pkg_ord,pkgver_ord=EXCLUDED.pkgver_ord
      """,
      arrays ++ [@revision]
    )
  end
end
