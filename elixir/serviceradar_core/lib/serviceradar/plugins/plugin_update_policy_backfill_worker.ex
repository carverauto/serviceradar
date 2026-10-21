defmodule ServiceRadar.Plugins.PluginUpdatePolicyBackfillWorker do
  @moduledoc """
  One-off backfill of the Wasm plugin update policy, enqueued once by migration
  `20261020143700_add_plugin_update_policy`.

  The migration marks every manual assignment and target policy that existed at
  the time `update_policy: pinned`, `update_policy_source: migration_default`.
  This worker moves the ones whose package is a signed, verified first-party
  package to `track_latest_approved`, the default a new owner of that package
  gets (see `ServiceRadar.Plugins.PluginUpdatePolicy.trusted_first_party?/1`,
  whose conditions the SQL below repeats). Everything else stays `pinned`.

  Converted rows keep `update_policy_source = migration_default`: the value is
  still the migration's choice, not an operator's.

  Each batch locks at most `@batch_size` candidate rows with `SKIP LOCKED`, so it
  never waits on a writer, and its UPDATE re-checks `migration_default`, so an
  operator choice committed before or during the backfill is never overwritten.
  A row skipped because a writer held it is picked up by a later batch; the job
  snoozes while any candidate remains. Re-running is a no-op.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 20

  alias ServiceRadar.Repo

  require Logger

  @batch_size 500
  @max_batches_per_run 100
  @retry_seconds 60

  @trusted_package """
  package.source_type = 'first_party'
    AND package.verification_status = 'verified'
    AND package.verification_error IS NULL
    AND package.signature IS NOT NULL
    AND package.signature <> '{}'::jsonb
    AND EXISTS (
      SELECT 1 FROM platform.plugin_repositories AS repository
      WHERE repository.builtin
        AND repository.artifact_kind = 'wasm_plugin'
        AND repository.repo_url = package.source_repo_url
    )
  """

  @assignment_candidates """
  FROM platform.plugin_assignments AS owner
  JOIN platform.plugin_packages AS package ON package.id = owner.plugin_package_id
  WHERE owner.update_policy_source = 'migration_default'
    AND owner.update_policy = 'pinned'
    AND owner.source = 'manual'
    AND #{@trusted_package}
  """

  @target_policy_candidates """
  FROM platform.plugin_target_policies AS owner
  JOIN platform.plugin_packages AS package ON package.id = owner.plugin_package_id
  WHERE owner.update_policy_source = 'migration_default'
    AND owner.update_policy = 'pinned'
    AND #{@trusted_package}
  """

  @tables [
    assignments: {"plugin_assignments", @assignment_candidates},
    target_policies: {"plugin_target_policies", @target_policy_candidates}
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    summary = run_batches(Repo, @batch_size, @max_batches_per_run)
    Logger.info("Wasm plugin update policy backfill pass", summary: inspect(summary))

    if pending?(Repo), do: {:snooze, @retry_seconds}, else: :ok
  end

  @doc """
  Converts one batch of each owner table and returns how many rows changed.
  """
  @spec backfill_batch(module(), pos_integer()) :: %{
          assignments: non_neg_integer(),
          target_policies: non_neg_integer()
        }
  def backfill_batch(repo \\ Repo, batch_size \\ @batch_size)
      when is_atom(repo) and is_integer(batch_size) and batch_size > 0 do
    Map.new(@tables, fn {key, {table, candidates}} ->
      %{num_rows: converted} = repo.query!(convert_sql(table, candidates), [batch_size])
      {key, converted}
    end)
  end

  defp run_batches(repo, batch_size, max_batches) do
    Enum.reduce_while(1..max_batches, %{assignments: 0, target_policies: 0}, fn _batch, total ->
      converted = backfill_batch(repo, batch_size)
      total = Map.merge(total, converted, fn _key, left, right -> left + right end)

      if Enum.any?(converted, fn {_key, count} -> count == batch_size end),
        do: {:cont, total},
        else: {:halt, total}
    end)
  end

  defp pending?(repo) do
    Enum.any?(@tables, fn {_key, {_table, candidates}} ->
      %{rows: [[pending?]]} = repo.query!("SELECT EXISTS (SELECT 1 #{candidates})")
      pending?
    end)
  end

  defp convert_sql(table, candidates) do
    """
    WITH batch AS (
      SELECT owner.id
      #{candidates}
      ORDER BY owner.id
      LIMIT $1
      FOR UPDATE OF owner SKIP LOCKED
    )
    UPDATE platform.#{table} AS owner
    SET update_policy = 'track_latest_approved'
    FROM batch
    WHERE owner.id = batch.id
      AND owner.update_policy_source = 'migration_default'
      AND owner.update_policy = 'pinned'
    """
  end
end
