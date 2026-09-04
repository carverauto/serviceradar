defmodule ServiceRadar.Inventory.AdvisoryFeeds.StagingCleanupWorker do
  @moduledoc """
  Periodic reaper for advisory-feed staging directories.

  `FeedWorker` timeouts kill the process with `:kill`, so `after` cleanup does
  not run. Combined with a new run id per attempt, leftover nist-nvd2 extracts
  filled a demo node (~255 GiB). This worker is the independent sweeper:

    * keep at most one nist-nvd2 dir, and only while a load is executing
    * drop every nist-nvd2 dir when no load is executing
    * apply the same executing-aware rule to the compact Ubuntu feed
    * age-reap tiny KEV leftovers

  It runs even when nist-nvd2 is disabled. The feed scheduler seeds it; the
  worker then reschedules itself so a later scheduler outage cannot leave
  extracts on disk.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Inventory.AdvisoryFeeds.FeedWorker
  alias ServiceRadar.Inventory.AdvisoryFeeds.Staging
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_reschedule_seconds 60
  @min_reschedule_seconds 60

  @doc "Seed the first cleanup job if none is already in flight."
  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    # Disk safety must not wait on the queue. The scheduler tick reaps here;
    # perform/1 is the backstop that keeps running if the scheduler later dies.
    _ = run_cleanup()

    if ObanSupport.available?() do
      if job_already_scheduled?() do
        {:ok, :already_scheduled}
      else
        %{} |> new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  @impl Oban.Worker
  def perform(_job) do
    stats = run_cleanup()

    Logger.info(
      "advisory_feeds: staging cleanup removed #{stats.removed_dirs} dirs (nist_keep=#{stats.nist_keep})"
    )

    schedule_next()
    :ok
  end

  @doc """
  Reap leftover staging dirs.

  `nist_keep` defaults to 1 only while a nist-nvd2 `FeedWorker` is executing.
  Retryable/scheduled jobs do not keep a leftover — the next `do_run` starts a
  new run id after `prune_feed(keep: 0)`.
  """
  @spec run_cleanup(keyword()) :: %{
          removed_dirs: non_neg_integer(),
          nist_keep: non_neg_integer(),
          ubuntu_keep: non_neg_integer()
        }
  def run_cleanup(opts \\ []) do
    nist_keep = Keyword.get_lazy(opts, :nist_keep, &default_nist_keep/0)
    ubuntu_keep = Keyword.get_lazy(opts, :ubuntu_keep, &default_ubuntu_keep/0)

    reap_opts =
      opts
      |> Keyword.take([:root, :now, :max_age_seconds])
      |> Keyword.put(:nist_keep, nist_keep)
      |> Keyword.put(:ubuntu_keep, ubuntu_keep)

    {:ok, removed} = Staging.reap_orphans(reap_opts)
    %{removed_dirs: removed, nist_keep: nist_keep, ubuntu_keep: ubuntu_keep}
  end

  @doc false
  @spec reschedule_seconds() :: pos_integer()
  def reschedule_seconds do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:reschedule_seconds, @default_reschedule_seconds)
    |> normalize_positive(@default_reschedule_seconds)
    |> max(@min_reschedule_seconds)
  end

  defp default_nist_keep do
    if FeedWorker.in_flight?("nist-nvd2", states: ["executing"]), do: 1, else: 0
  end

  defp default_ubuntu_keep do
    if FeedWorker.in_flight?("ubuntu-osv-vex", states: ["executing"]), do: 1, else: 0
  end

  defp schedule_next do
    _ =
      ObanSupport.safe_insert(
        SelfScheduling.successor_changeset(__MODULE__, %{}, reschedule_seconds())
      )

    :ok
  end

  defp job_already_scheduled? do
    worker = inspect(__MODULE__)

    query =
      from(j in Oban.Job,
        where: j.worker == ^worker,
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  rescue
    _ -> false
  end

  defp normalize_positive(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive(_value, default), do: default
end
