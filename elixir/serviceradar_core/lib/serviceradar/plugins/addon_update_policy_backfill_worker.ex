defmodule ServiceRadar.Plugins.AddonUpdatePolicyBackfillWorker do
  @moduledoc """
  Moves legacy native add-on sources onto trusted automatic update policy.

  The rollout schema migration only marks rows that existed when the columns
  were introduced. This one-shot Oban worker drains those rows in bounded,
  skip-locked batches after startup so a large fleet cannot block application
  boot or overwrite an operator choice made after the migration.
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 10,
    unique: [period: :infinity, fields: [:worker, :args], states: :successful]

  import Ecto.Query, warn: false

  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @backfill_version "20260718140000"
  @batch_size 500

  @assignment_backfill_sql """
  WITH batch AS (
    SELECT assignment.id,
           assignment.source <> 'profile'
             AND assignment.explicit_version_pin = FALSE
             AND package.source_type = 'first_party'
             AND package.verification_status = 'verified'
             AND package.verification_error IS NULL
             AND package.status = 'approved' AS track_latest,
           COALESCE(package.approved_capabilities, ARRAY[]::text[]) AS approved_capabilities
    FROM platform.addon_assignments AS assignment
    LEFT JOIN platform.addon_packages AS package
      ON package.id = assignment.addon_package_id
    WHERE assignment.update_policy_backfill_pending = TRUE
    ORDER BY assignment.id
    LIMIT $1
    FOR UPDATE OF assignment SKIP LOCKED
  )
  UPDATE platform.addon_assignments AS assignment
  SET update_policy = CASE
        WHEN batch.track_latest THEN 'track_latest_approved'
        ELSE assignment.update_policy
      END,
      capability_ceiling = CASE
        WHEN batch.track_latest THEN batch.approved_capabilities
        ELSE assignment.capability_ceiling
      END,
      update_policy_backfill_pending = FALSE
  FROM batch
  WHERE assignment.id = batch.id
  """

  @profile_backfill_sql """
  WITH batch AS (
    SELECT profile.id,
           profile.explicit_version_pin = FALSE
             AND package.source_type = 'first_party'
             AND package.verification_status = 'verified'
             AND package.verification_error IS NULL
             AND package.status = 'approved' AS track_latest,
           COALESCE(package.approved_capabilities, ARRAY[]::text[]) AS approved_capabilities
    FROM platform.addon_profiles AS profile
    LEFT JOIN platform.addon_packages AS package
      ON package.id = profile.addon_package_id
    WHERE profile.update_policy_backfill_pending = TRUE
    ORDER BY profile.id
    LIMIT $1
    FOR UPDATE OF profile SKIP LOCKED
  )
  UPDATE platform.addon_profiles AS profile
  SET update_policy = CASE
        WHEN batch.track_latest THEN 'track_latest_approved'
        ELSE profile.update_policy
      END,
      capability_ceiling = CASE
        WHEN batch.track_latest THEN batch.approved_capabilities
        ELSE profile.capability_ceiling
      END,
      update_policy_backfill_pending = FALSE
  FROM batch
  WHERE profile.id = batch.id
  """

  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if backfill_scheduled?() do
        {:ok, :already_scheduled}
      else
        %{"migration_version" => @backfill_version}
        |> new()
        |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case backfill_batch() do
      {:ok, %{assignments: assignments, profiles: profiles} = summary} ->
        Logger.info("Backfilled native add-on update policy", summary: inspect(summary))

        if assignments == @batch_size or profiles == @batch_size do
          {:snooze, 1}
        else
          :ok
        end

      {:error, reason} ->
        Logger.warning("Native add-on update policy backfill failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  @doc false
  @spec backfill_batch(module(), pos_integer()) ::
          {:ok, %{assignments: non_neg_integer(), profiles: non_neg_integer()}}
          | {:error, term()}
  def backfill_batch(repo \\ Repo, batch_size \\ @batch_size)

  def backfill_batch(repo, batch_size)
      when is_atom(repo) and is_integer(batch_size) and batch_size > 0 do
    repo.transaction(fn ->
      with {:ok, assignment_result} <- repo.query(@assignment_backfill_sql, [batch_size]),
           {:ok, profile_result} <- repo.query(@profile_backfill_sql, [batch_size]) do
        %{assignments: assignment_result.num_rows, profiles: profile_result.num_rows}
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  @doc false
  @spec backfill_scheduled?() :: boolean()
  def backfill_scheduled? do
    query =
      from(job in Oban.Job,
        where: job.worker == ^to_string(__MODULE__),
        where: job.state in ^successful_state_names(),
        where: fragment("?->>'migration_version' = ?", job.args, ^@backfill_version),
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  # Oban.Job.unique_states/1 returns atoms, but Oban.Job.state is a :string
  # field - interpolating the atoms raises Ecto.Query.CastError at runtime
  # (crash-looped every core in v1.4.24; see issue #4645).
  @doc false
  @spec successful_state_names() :: [String.t()]
  def successful_state_names do
    :successful
    |> Oban.Job.unique_states()
    |> Enum.map(&to_string/1)
  end
end
