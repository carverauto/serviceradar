defmodule ServiceRadarWebNG.Plugins.FirstPartySyncWorker do
  @moduledoc """
  Periodically imports verified first-party Wasm plugin packages from GitHub Releases.
  """

  use Oban.Worker,
    queue: :web_maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport
  alias ServiceRadarWebNG.Plugins.FirstPartyReleaseClient
  alias ServiceRadarWebNG.Plugins.Packages
  alias ServiceRadarWebNG.Plugins.Repositories

  require Logger

  @default_release_limit 10
  @default_reschedule_seconds 3_600
  @bootstrap_unique [period: :infinity, states: :incomplete]
  @successor_unique [period: :infinity, states: [:available, :scheduled, :retryable]]
  @bootstrap_states ["available", "scheduled", "executing", "retryable", "suspended"]
  @manual_unique [period: :infinity, states: :incomplete, keys: [:force]]

  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if check_existing_job() do
        {:ok, :already_scheduled}
      else
        %{} |> bootstrap_job(schedule_in: 60) |> ObanSupport.safe_insert()
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
      |> maybe_put("release_tag", Keyword.get(opts, :release_tag))
      |> maybe_put("limit", Keyword.get(opts, :limit))

    args
    |> manual_job()
    |> ObanSupport.safe_insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    force? = Map.get(args || %{}, "force") == true

    result =
      if force? or auto_sync_enabled?() do
        run_sync(args || %{})
      else
        Logger.debug("First-party Wasm plugin sync skipped because auto-sync is disabled")
        :ok
      end

    if !force? and result == :ok do
      schedule_next()
    end

    result
  end

  defp run_sync(args) do
    actor = SystemActor.system(:first_party_plugin_sync)

    case target_repositories(args, actor) do
      [] ->
        Logger.info("Wasm plugin sync found no enabled repositories")
        :ok

      repositories ->
        # Each repository is synced independently on purpose. One unreachable
        # private source -- an expired token, a repo that moved -- must not stop
        # the others from importing, and before repositories were records there
        # was only one source so there was nothing to isolate.
        results = Enum.map(repositories, &sync_repository(&1, args, actor))

        aggregate_results(results)
    end
  end

  @doc """
  Folds per-repository sync outcomes into the Oban job result.

  Any failure a retry could still resolve (expired token, HTTP 5xx, invalid
  settings -- including atom reasons such as `:invalid_attributes`) fails the
  job as `:partial_plugin_sync_failure` so Oban retries, but only after every
  repository has had its turn. A failure that describes the published release
  itself -- an unpublished tag, or a release carrying no plugin index asset --
  reports identically on all three attempts, so the per-repository
  `last_sync_error` records why and the job succeeds, leaving the next attempt
  to the hourly successor.
  """
  @spec aggregate_results([:ok | {:error, term()}]) :: :ok | {:error, :partial_plugin_sync_failure}
  def aggregate_results(results) when is_list(results) do
    retryable? =
      Enum.any?(results, fn
        {:error, reason} -> not FirstPartyReleaseClient.permanent_failure?(reason)
        _ -> false
      end)

    if retryable?, do: {:error, :partial_plugin_sync_failure}, else: :ok
  end

  defp sync_repository(repository, args, actor) do
    case Repositories.import_attrs(repository, actor: actor) do
      {:ok, import_attrs} ->
        opts =
          Keyword.put(
            [
              actor: actor,
              allow_release_fallback: true,
              repo_url: import_attrs["repo_url"],
              index_asset_name: import_attrs["index_asset_name"],
              github_token: import_attrs["github_token"],
              trusted_upload_signing_keys: import_attrs["trusted_upload_signing_keys"],
              limit: release_limit(args)
            ],
            :release_tag,
            release_tag(args)
          )

        case Packages.sync_first_party_plugins(opts) do
          {:ok, summary} ->
            Logger.info(
              "Wasm plugin sync completed for #{repository.repo_url}: discovered=#{summary.discovered} " <>
                "import_ready=#{summary.import_ready} imported=#{summary.imported} failed=#{length(summary.failed)}"
            )

            log_import_failures(summary.failed)
            record_success(repository, actor)
            :ok

          {:error, reason} ->
            Logger.warning("Wasm plugin sync failed for #{repository.repo_url}", reason: inspect(reason))
            record_failure(repository, reason, actor)
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning(
          "Wasm plugin sync could not resolve credentials for #{repository.repo_url}",
          reason: inspect(reason)
        )

        record_failure(repository, reason, actor)
        {:error, reason}
    end
  end

  # An explicit repo_url (from `enqueue_now/1`) still works: it selects one
  # repository rather than bypassing the registry, so a manual sync cannot pull
  # from a source nobody registered.
  defp target_repositories(args, actor) do
    case Map.get(args, "repo_url") do
      url when is_binary(url) and url != "" ->
        case Repositories.get_by_repo_url(url, actor: actor) do
          {:ok, repository} ->
            [repository]

          {:error, _reason} ->
            Logger.warning("Wasm plugin sync requested an unregistered repository: #{url}")
            []
        end

      _ ->
        Repositories.list_enabled(actor: actor)
    end
  end

  defp record_success(repository, actor) do
    repository
    |> Ash.Changeset.for_update(:record_sync_success, %{}, actor: actor)
    |> Ash.update()
    |> log_stamp_failure(repository)
  end

  defp record_failure(repository, reason, actor) do
    repository
    |> Ash.Changeset.for_update(:record_sync_error, %{last_sync_error: inspect(reason)}, actor: actor)
    |> Ash.update()
    |> log_stamp_failure(repository)
  end

  defp log_stamp_failure({:ok, _record}, _repository), do: :ok

  defp log_stamp_failure({:error, error}, repository) do
    Logger.warning("Could not stamp sync state on #{repository.repo_url}", reason: inspect(error))
    :ok
  end

  defp schedule_next do
    if auto_sync_enabled?() and ObanSupport.available?() do
      case ObanSupport.safe_insert(successor_job(%{}, schedule_in: reschedule_seconds())) do
        {:ok, %Oban.Job{}} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to schedule the next first-party Wasm plugin sync", reason: inspect(reason))
      end
    end

    :ok
  end

  defp check_existing_job do
    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ^@bootstrap_states,
        where: fragment("COALESCE(?->>'force', 'false') <> 'true'", j.args),
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  defp auto_sync_enabled? do
    Keyword.get(config(), :auto_sync_enabled, false)
  end

  defp release_tag(args) do
    normalize_optional_string(Map.get(args, "release_tag")) ||
      normalize_optional_string(Keyword.get(config(), :release_tag)) ||
      normalize_optional_string(System.get_env("SERVICERADAR_RELEASE_VERSION"))
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

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp config do
    Application.get_env(:serviceradar_web_ng, :first_party_plugin_import, [])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp bootstrap_job(args, opts), do: new(args, Keyword.put(opts, :unique, @bootstrap_unique))
  defp successor_job(args, opts), do: new(args, Keyword.put(opts, :unique, @successor_unique))
  defp manual_job(args), do: new(args, unique: @manual_unique)

  defp log_import_failures(failures) do
    Enum.each(failures, fn failure ->
      Logger.warning("First-party Wasm plugin import failed",
        plugin_id: Map.get(failure, :plugin_id),
        version: Map.get(failure, :version),
        release_tag: Map.get(failure, :release_tag),
        reason: inspect(Map.get(failure, :error), limit: 20, printable_limit: 1_000)
      )
    end)
  end
end
