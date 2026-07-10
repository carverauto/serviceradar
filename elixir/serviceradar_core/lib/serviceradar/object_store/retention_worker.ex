defmodule ServiceRadar.ObjectStore.RetentionWorker do
  @moduledoc """
  Oban worker for ServiceRadar-owned Object Store retention.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.ObjectStore.NativeAddonArtifactRetention
  alias ServiceRadar.ObjectStore.ReleaseArtifactRetention
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @doc """
  Enqueue a manual object store retention run.
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
      dry_run? = bool_arg(args, "dry_run", config(:dry_run?, true))

      keep_latest =
        int_arg(args, "agent_release_keep_latest", config(:agent_release_keep_latest, 5))

      native_addon_orphan_grace_seconds =
        int_arg(
          args,
          "native_addon_orphan_grace_seconds",
          config(:native_addon_orphan_grace_seconds, 604_800)
        )

      datasvc_timeout_ms =
        int_arg(args, "datasvc_timeout_ms", config(:datasvc_timeout_ms, 30_000))

      with {:ok, _release_summary} <-
             release_retention_module().run(
               dry_run?: dry_run?,
               keep_latest: keep_latest,
               timeout: datasvc_timeout_ms
             ),
           {:ok, _addon_summary} <-
             native_addon_retention_module().run(
               dry_run?: dry_run?,
               native_addon_orphan_grace_seconds: native_addon_orphan_grace_seconds,
               timeout: datasvc_timeout_ms
             ) do
        :ok
      else
        {:error, reason} ->
          Logger.warning("ObjectStoreRetentionWorker failed", reason: inspect(reason))
          {:error, reason}
      end
    else
      Logger.debug(
        "ObjectStoreRetentionWorker skipped because object store retention is disabled"
      )

      :ok
    end
  end

  defp manual_args(opts) do
    %{"enabled" => true, "manual" => true}
    |> maybe_put("dry_run", Keyword.get(opts, :dry_run?))
    |> maybe_put("agent_release_keep_latest", Keyword.get(opts, :agent_release_keep_latest))
    |> maybe_put(
      "native_addon_orphan_grace_seconds",
      Keyword.get(opts, :native_addon_orphan_grace_seconds)
    )
    |> maybe_put("datasvc_timeout_ms", Keyword.get(opts, :datasvc_timeout_ms))
  end

  defp enabled?(args) do
    bool_arg(args, "enabled", config(:enabled?, false))
  end

  defp config(key, default) do
    :serviceradar_core
    |> Application.get_env(:object_store_retention, [])
    |> Keyword.get(key, default)
  end

  defp release_retention_module do
    config(:release_artifact_retention_module, ReleaseArtifactRetention)
  end

  defp native_addon_retention_module do
    config(:native_addon_artifact_retention_module, NativeAddonArtifactRetention)
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
