defmodule ServiceRadar.Inventory.ExposureSnapshotScopes do
  @moduledoc """
  Pending scopes for the single exposure snapshot publisher.

  Replaces the per-device `ExposureSnapshotWorker` Oban fan-out: demand paths
  write one row per scope here and ensure the singleton publisher job, which
  drains due rows oldest-first and exits when the table is empty. One row per
  scope (`scope_ord`, NULL for the fleet-wide scope), updated in place;
  completed rows persist as the publish ledger. Rows are never deleted by the
  publisher: failures back off and retry, and dead rows wait for the next
  demand signal.

  Fresh demand resets attempts: a re-pended scope is a new obligation even
  when an earlier one poisoned.
  """

  alias ServiceRadar.Inventory.ExposureSnapshotPublisherWorker
  alias ServiceRadar.Repo

  @table "platform.exposure_snapshot_scopes"
  @dead_attempts 10
  @lease_seconds 1_800
  @backoff_seconds 30
  @backoff_cap_seconds 3_600

  @doc "Records demand for a scope (nil for fleet-wide) and ensures the publisher."
  def request(scope) when is_nil(scope) or (is_integer(scope) and scope >= 1) do
    # Resetting a row a live publisher holds is safe: the publisher owns its
    # pass through the session advisory lock, so no second pass can claim the
    # re-pended row until the holder exits, and id-keyed completion still lands.

    Repo.query!(
      """
      INSERT INTO #{@table} (scope_ord, status, attempts, not_before, error, updated_at)
      VALUES ($1, 'pending', 0, now(), NULL, now())
      ON CONFLICT (scope_ord) DO UPDATE
        SET status = 'pending', attempts = 0, not_before = now(), error = NULL,
            generation_id = NULL, claimed_by = NULL, lease_expires_at = NULL,
            updated_at = now()
      """,
      [scope]
    )

    ensure_publisher()
  end

  @doc "Ensures one publisher job; a no-op while one is pending or scheduled."
  def ensure_publisher do
    # Unique on [:worker] over available/scheduled: an executing job never
    # blocks the next ensure, so a crashed publisher resumes without waiting
    # out the stale-row reap. The session advisory lock serializes publishers;
    # a run that finds the lock held exits quietly because the running drain
    # already covers the table.
    case %{} |> ExposureSnapshotPublisherWorker.new() |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, _reason} -> :ok
    end
  end

  @doc "Claims the oldest due row for `job_id`, or `:none` when the table is quiet."
  def claim(job_id) do
    case Repo.query(
           """
           UPDATE #{@table}
           SET status = 'publishing', generation_id = NULL, claimed_by = $1,
               lease_expires_at = now() + make_interval(secs => $2), updated_at = now()
           WHERE id = (
             SELECT id FROM #{@table}
             WHERE status IN ('pending', 'preparing', 'failed') AND not_before <= now()
             ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED
           )
           RETURNING id, scope_ord
           """,
           [job_id, @lease_seconds]
         ) do
      {:ok, %{rows: [[id, scope]]}} -> {:ok, %{id: id, scope_ord: scope}}
      {:ok, %{rows: []}} -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Marks a scope complete when its claim still tracks the completed generation."
  def complete(id, generation_id) do
    Repo.query!(
      """
      UPDATE #{@table} SET status = 'complete', error = NULL, updated_at = now()
      WHERE id = $1 AND status = 'publishing' AND generation_id = $2
      """,
      [id, generation_id]
    )

    :ok
  end

  @doc """
  Adopts a legacy queue scope: inserts it `pending` when no row exists (never
  touching an existing row) and ensures the publisher. Queue-executed legacy
  jobs call this instead of publishing, so no old-format row survives an
  upgrade by snoozing.
  """
  def adopt_legacy(scope) when is_integer(scope) and scope >= 1 do
    Repo.query!(
      """
      INSERT INTO #{@table} (scope_ord, status, attempts, not_before, error, updated_at)
      VALUES ($1, 'pending', 0, now(), NULL, now())
      ON CONFLICT (scope_ord) DO NOTHING
      """,
      [scope]
    )

    ensure_publisher()
  end

  @doc "Parks a scope for preparation with backoff; the prepare completion re-ensures."
  def defer_preparing(id) do
    Repo.query!(
      """
      UPDATE #{@table}
      SET status = 'preparing', not_before = now() + make_interval(secs => $2),
          updated_at = now()
      WHERE id = $1 AND status = 'publishing'
      """,
      [id, @backoff_seconds]
    )

    :ok
  end

  @doc """
  Records a scope failure with backoff, or dead-letters past the cap. Returns
  `:ok` without counting an attempt when fresh demand already re-pended the row.
  """
  def fail(id, reason) do
    case Repo.query(
           """
           UPDATE #{@table}
           SET attempts = attempts + 1,
               status = CASE WHEN attempts + 1 >= $5 THEN 'dead' ELSE 'failed' END,
               not_before = now() + make_interval(secs => LEAST($2 * (attempts + 1), $3)),
               error = $4, updated_at = now()
           WHERE id = $1 AND status = 'publishing'
           RETURNING attempts
           """,
           [id, @backoff_seconds, @backoff_cap_seconds, encode_reason(reason), @dead_attempts]
         ) do
      {:ok, %{rows: []}} ->
        :ok

      {:ok, %{rows: [[attempts]]}} when attempts >= @dead_attempts ->
        :telemetry.execute(
          [:serviceradar, :exposure, :snapshot, :scope_dead],
          %{attempts: attempts},
          %{scope_id: id}
        )

        {:dead, attempts}

      {:ok, %{rows: [[attempts]]}} ->
        {:failed, attempts}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp encode_reason(reason) when is_exception(reason), do: Exception.message(reason)
  defp encode_reason(reason) when is_atom(reason) or is_binary(reason), do: to_string(reason)
  defp encode_reason(reason), do: inspect(reason)

  @doc "Publishing rows whose lease expired, oldest first, for orphan adoption."
  def expired_publishing do
    Repo.query!(
      """
      SELECT id, scope_ord, generation_id FROM #{@table}
      WHERE status = 'publishing' AND lease_expires_at < now()
      ORDER BY id FOR UPDATE SKIP LOCKED
      """,
      []
    ).rows
  end

  @doc """
  Releases a claim without re-pending: the row stays `publishing` with an
  expired lease, so the next pass adopts it — completing without republish
  when its generation finished, republishing only when it did not.
  """
  def release(id) do
    Repo.query!(
      """
      UPDATE #{@table}
      SET claimed_by = NULL, lease_expires_at = now() - make_interval(secs => 1), updated_at = now()
      WHERE id = $1 AND status = 'publishing'
      """,
      [id]
    )

    :ok
  end

  @doc "Re-pends an adopted scope after its orphaned generation was aborted."
  def requeue(id) do
    Repo.query!(
      """
      UPDATE #{@table}
      SET status = 'pending', generation_id = NULL, claimed_by = NULL,
          lease_expires_at = NULL, not_before = now(), updated_at = now()
      WHERE id = $1 AND status = 'publishing'
      """,
      [id]
    )

    :ok
  end

  @doc "Records which generation is publishing a claimed scope."
  def track_generation(id, generation_id) do
    Repo.query!(
      """
      UPDATE #{@table} SET generation_id = $2, updated_at = now()
      WHERE id = $1 AND status = 'publishing'
      """,
      [id, generation_id]
    )

    :ok
  end

  @doc "Whether any scope row still needs a publisher pass."
  def pending? do
    Repo.query!(
      "SELECT 1 FROM #{@table} WHERE status IN ('pending', 'publishing', 'preparing', 'failed') LIMIT 1",
      []
    ).rows != []
  end
end
