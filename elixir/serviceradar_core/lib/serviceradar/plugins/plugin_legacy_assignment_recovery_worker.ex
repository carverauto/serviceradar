defmodule ServiceRadar.Plugins.PluginLegacyAssignmentRecoveryWorker do
  @moduledoc """
  Periodically converges trusted first-party manual assignments quarantined by
  the partition-binding migration.

  Policy-owned history is deliberately ignored here; the normal policy and
  credential-rule reconcilers rebuild desired state from current authority.
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.Plugins.PluginAssignmentRecovery
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @batch_size 100
  @default_reschedule_seconds 300

  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if scheduled?(), do: {:ok, :already_scheduled}, else: enqueue(%{})
    else
      {:error, :oban_unavailable}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    opts = maybe_put_after_id([limit: @batch_size], args["after_id"])

    case PluginAssignmentRecovery.recover_automatic(opts) do
      {:ok, summary} ->
        Logger.info("Automatic legacy plugin recovery sweep completed",
          scanned: summary.scanned,
          manual_candidates: summary.manual_candidates,
          recovered: summary.recovered,
          deferred: summary.deferred,
          failed: summary.failed
        )

        schedule_next(summary)
        :ok

      {:error, reason} ->
        Logger.warning("Automatic legacy plugin recovery sweep deferred",
          reason: inspect(reason)
        )

        schedule_periodic()
        :ok
    end
  end

  defp maybe_put_after_id(opts, after_id) when is_binary(after_id),
    do: Keyword.put(opts, :after_id, after_id)

  defp maybe_put_after_id(opts, _after_id), do: opts

  defp schedule_next(%{more?: true, next_after_id: after_id}) when is_binary(after_id) do
    _ = enqueue(%{"after_id" => after_id})
    :ok
  end

  defp schedule_next(_summary), do: schedule_periodic()

  defp schedule_periodic do
    seconds =
      Application.get_env(
        :serviceradar_core,
        :plugin_legacy_assignment_recovery_interval_seconds,
        @default_reschedule_seconds
      )

    _ =
      ObanSupport.safe_insert(
        SelfScheduling.successor_changeset(__MODULE__, %{}, max(seconds, 30))
      )

    :ok
  end

  defp enqueue(args) do
    args
    |> new()
    |> ObanSupport.safe_insert()
  end

  defp scheduled? do
    import Ecto.Query

    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    ServiceRadar.Repo.exists?(query, prefix: ObanSupport.prefix())
  end
end
