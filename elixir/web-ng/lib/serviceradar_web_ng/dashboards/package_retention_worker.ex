defmodule ServiceRadarWebNG.Dashboards.PackageRetentionWorker do
  @moduledoc """
  Oban worker for dashboard package version retention.

  Keeps only the N most-recent versions per dashboard_id, deleting older
  WASM blobs from the object store and the corresponding DB records.
  Enabled packages and packages referenced by a DashboardInstance are
  always protected.

  Configured via `:serviceradar_web_ng, :dashboard_package_retention`.
  Triggered daily by `Oban.Plugins.Cron` when
  `DASHBOARD_PACKAGE_RETENTION_ENABLED=true`.
  """

  use Oban.Worker,
    queue: :web_maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.SweepJobs.ObanSupport
  alias ServiceRadarWebNG.Dashboards.PackageRetention

  require Logger

  @doc """
  Enqueue a manual dashboard package retention run.
  """
  @spec enqueue_manual(keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_manual(opts \\ []) do
    if ObanSupport.available?() do
      opts
      |> manual_args()
      |> new()
      |> ObanSupport.safe_insert()
    else
      {:error, :oban_unavailable}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if enabled?(args) do
      keep_versions = int_arg(args, "keep_versions", config(:keep_versions, 2))
      dry_run? = bool_arg(args, "dry_run", config(:dry_run?, false))

      case PackageRetention.run(keep_versions: keep_versions, dry_run?: dry_run?) do
        {:ok, summary} ->
          Logger.info("DashboardPackageRetention completed",
            scanned: summary.scanned,
            protected: summary.protected,
            eligible: summary.eligible,
            deleted_blobs: summary.deleted_blobs,
            deleted_records: summary.deleted_records,
            failed: summary.failed,
            dry_run: summary.dry_run
          )

          :ok

        {:error, reason} ->
          Logger.warning("DashboardPackageRetention failed", reason: inspect(reason))
          {:error, reason}
      end
    else
      Logger.debug("DashboardPackageRetentionWorker skipped (disabled)")
      :ok
    end
  end

  defp enabled?(args), do: bool_arg(args, "enabled", config(:enabled?, false))

  defp manual_args(opts) do
    %{"enabled" => true, "manual" => true}
    |> maybe_put("dry_run", Keyword.get(opts, :dry_run?))
    |> maybe_put("keep_versions", Keyword.get(opts, :keep_versions))
  end

  defp config(key, default) do
    :serviceradar_web_ng
    |> Application.get_env(:dashboard_package_retention, [])
    |> Keyword.get(key, default)
  end

  defp bool_arg(args, key, default) do
    case Map.get(args, key) do
      value when value in [true, "true", "1", 1, "yes"] -> true
      value when value in [false, "false", "0", 0, "no"] -> false
      _ -> default
    end
  end

  defp int_arg(args, key, default) do
    case Map.get(args, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_int(value, default)
      _ -> default
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end
end
