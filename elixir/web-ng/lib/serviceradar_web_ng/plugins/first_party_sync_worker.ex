defmodule ServiceRadarWebNG.Plugins.FirstPartySyncWorker do
  @moduledoc """
  Periodically imports verified first-party Wasm plugin packages from Forgejo releases.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport
  alias ServiceRadarWebNG.Plugins.Packages

  require Logger

  @default_release_limit 10
  @default_reschedule_seconds 3_600

  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if check_existing_job() do
        {:ok, :already_scheduled}
      else
        %{} |> new(schedule_in: 60) |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  @spec enqueue_now(keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_now(opts \\ []) do
    args =
      %{"force" => true}
      |> maybe_put("repo_url", Keyword.get(opts, :repo_url))
      |> maybe_put("limit", Keyword.get(opts, :limit))

    args
    |> new()
    |> ObanSupport.safe_insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    force? = Map.get(args || %{}, "force") == true

    try do
      if force? or auto_sync_enabled?() do
        run_sync(args || %{})
      else
        Logger.debug("First-party Wasm plugin sync skipped because auto-sync is disabled")
        :ok
      end
    after
      if !force? do
        schedule_next()
      end
    end
  end

  defp run_sync(args) do
    actor = SystemActor.system(:first_party_plugin_sync)
    opts = [actor: actor, repo_url: repo_url(args), limit: release_limit(args)]

    case Packages.sync_first_party_plugins(opts) do
      {:ok, summary} ->
        Logger.info(
          "First-party Wasm plugin sync completed: discovered=#{summary.discovered} " <>
            "import_ready=#{summary.import_ready} imported=#{summary.imported} failed=#{length(summary.failed)}"
        )

        :ok

      {:error, reason} ->
        Logger.warning("First-party Wasm plugin sync failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp schedule_next do
    if auto_sync_enabled?() and ObanSupport.available?() do
      _ = ObanSupport.safe_insert(new(%{}, schedule_in: reschedule_seconds()))
    end

    :ok
  end

  defp check_existing_job do
    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  defp auto_sync_enabled? do
    Keyword.get(config(), :auto_sync_enabled, false)
  end

  defp repo_url(args) do
    Map.get(args, "repo_url") || Keyword.get(config(), :repo_url)
  end

  defp release_limit(args) do
    args
    |> Map.get("limit")
    |> normalize_positive_integer(Keyword.get(config(), :sync_release_limit, @default_release_limit))
  end

  defp reschedule_seconds do
    config()
    |> Keyword.get(:sync_interval_seconds, @default_reschedule_seconds)
    |> normalize_positive_integer(@default_reschedule_seconds)
    |> max(300)
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  defp config do
    Application.get_env(:serviceradar_web_ng, :first_party_plugin_import, [])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
