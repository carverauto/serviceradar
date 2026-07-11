defmodule ServiceRadarWebNG.Plugins.NativeAddonSyncWorker do
  @moduledoc """
  Periodically imports verified first-party native add-on packages from Forgejo releases.
  """

  use Oban.Worker,
    queue: :web_maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.RetiredNativeAddons
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport
  alias ServiceRadarWebNG.Plugins.NativeAddonImporter

  require Ash.Query
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
      |> maybe_put("release_tag", Keyword.get(opts, :release_tag))
      |> maybe_put("limit", Keyword.get(opts, :limit))

    args
    |> new()
    |> ObanSupport.safe_insert()
  end

  @impl Oban.Worker
  def timeout(_job), do: to_timeout(minute: 10)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    args = args || %{}
    force? = Map.get(args, "force") == true

    try do
      if force? or auto_sync_enabled?() do
        run_sync(args)
      else
        Logger.debug("First-party native add-on sync skipped because auto-sync is disabled")
        :ok
      end
    after
      if !force? do
        schedule_next()
      end
    end
  end

  defp run_sync(args) do
    repo_url = repo_url(args)
    limit = release_limit(args)
    release_tag = optional_arg(args, "release_tag")
    addon_ids = requested_addon_ids(args)
    auto_approve_addon_ids = configured_auto_approve_addon_ids()
    discovery_attrs = maybe_put(%{}, :repo_url, repo_url)

    case NativeAddonImporter.list_recent_addons(discovery_attrs, limit) do
      {:ok, addons} ->
        results =
          addons
          |> maybe_filter_release_tag(release_tag)
          |> Enum.filter(
            &(Map.get(&1, :import_ready?) and selected_addon?(&1, addon_ids) and
                not RetiredNativeAddons.retired?(&1.addon_id))
          )
          |> dedupe_native_addon_versions()
          |> Enum.map(fn addon ->
            {addon, import_or_reuse(addon, auto_approve_addon_ids)}
          end)

        summary = summary(addons, results)

        Logger.info(
          "First-party native add-on sync completed: discovered=#{summary.discovered} " <>
            "import_ready=#{summary.import_ready} imported=#{summary.imported} " <>
            "skipped=#{summary.skipped} failed=#{length(summary.failed)}"
        )

        :ok

      {:error, reason} ->
        Logger.warning("First-party native add-on sync failed", reason: inspect(reason))
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
        where: j.state in ["available", "scheduled", "retryable"],
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  defp maybe_filter_release_tag(addons, release_tag) when is_binary(release_tag) and release_tag != "" do
    Enum.filter(addons, &(&1.release_tag == release_tag))
  end

  defp maybe_filter_release_tag(addons, _release_tag), do: addons

  defp selected_addon?(_addon, []), do: true
  defp selected_addon?(addon, addon_ids), do: addon.addon_id in addon_ids

  defp dedupe_native_addon_versions(addons) do
    addons
    |> Enum.reduce({MapSet.new(), []}, fn addon, {seen, acc} ->
      key = {addon.addon_id, addon.version}

      if MapSet.member?(seen, key) do
        {seen, acc}
      else
        {MapSet.put(seen, key), [addon | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp import_or_reuse(addon, auto_approve_addon_ids) do
    case existing_package(addon.addon_id, addon.version) do
      {:ok, nil} ->
        import_addon(addon, auto_approve_addon_ids)

      {:ok, %AddonPackage{} = package} ->
        cond do
          reusable_package?(package, addon) ->
            with {:ok, package} <- maybe_approve(package, auto_approve_addon_ids) do
              {:skipped, package}
            end

          source_conflict?(package, addon) ->
            {:error,
             {:native_addon_version_source_conflict,
              %{
                addon_id: addon.addon_id,
                version: addon.version,
                existing_oci_ref: package.source_oci_ref,
                existing_oci_digest: package.source_oci_digest,
                discovered_oci_ref: addon.oci_ref,
                discovered_oci_digest: addon.oci_digest
              }}}

          true ->
            import_addon(addon, auto_approve_addon_ids)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp import_addon(addon, auto_approve_addon_ids) do
    import_attrs = %{
      repo_url: addon.repo_url,
      release_tag: addon.release_tag,
      addon_id: addon.addon_id,
      version: addon.version
    }

    with {:ok, package} <- NativeAddonImporter.import(import_attrs),
         {:ok, package} <- maybe_approve(package, auto_approve_addon_ids) do
      {:imported, package}
    end
  end

  defp existing_package(addon_id, version) do
    actor = SystemActor.system(:native_addon_sync)

    AddonPackage
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(addon_id == ^addon_id and version == ^version)
    |> Ash.read_one(actor: actor)
  end

  defp reusable_package?(%AddonPackage{} = package, addon) do
    source_matches?(package, addon) and package.verification_status == "verified" and
      is_map(package.artifacts) and map_size(package.artifacts) > 0
  end

  defp source_conflict?(%AddonPackage{} = package, addon) do
    package.source_oci_ref not in [nil, ""] and package.source_oci_digest not in [nil, ""] and
      not source_matches?(package, addon)
  end

  defp source_matches?(%AddonPackage{} = package, addon) do
    package.source_oci_ref == addon.oci_ref and package.source_oci_digest == addon.oci_digest
  end

  defp maybe_approve(%AddonPackage{addon_id: addon_id, status: :staged} = package, auto_approve_addon_ids) do
    if addon_id in auto_approve_addon_ids do
      package
      |> Ash.Changeset.for_update(
        :approve,
        %{approved_capabilities: package.capabilities || [], approved_by: "system:native_addon_sync"},
        actor: SystemActor.system(:native_addon_sync)
      )
      |> Ash.update()
    else
      {:ok, package}
    end
  end

  defp maybe_approve(%AddonPackage{} = package, _auto_approve_addon_ids), do: {:ok, package}

  defp summary(discovered, results) do
    imported = Enum.count(results, fn {_addon, result} -> match?({:imported, _package}, result) end)
    skipped = Enum.count(results, fn {_addon, result} -> match?({:skipped, _package}, result) end)

    failed =
      results
      |> Enum.filter(fn {_addon, result} -> match?({:error, _reason}, result) end)
      |> Enum.map(fn {addon, {:error, reason}} ->
        %{
          addon_id: addon.addon_id,
          version: addon.version,
          release_tag: addon.release_tag,
          error: reason
        }
      end)

    %{
      discovered: length(discovered),
      import_ready: length(results),
      imported: imported,
      skipped: skipped,
      failed: failed
    }
  end

  defp auto_sync_enabled? do
    Keyword.get(config(), :auto_sync_enabled, false)
  end

  defp repo_url(args) do
    optional_arg(args, "repo_url") || Keyword.get(config(), :repo_url)
  end

  defp requested_addon_ids(args) do
    args
    |> optional_arg("addon_ids")
    |> normalize_string_list([])
  end

  defp configured_auto_approve_addon_ids do
    config()
    |> Keyword.get(:auto_approve_addon_ids, [])
    |> normalize_string_list([])
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

  defp normalize_string_list(value, _default) when is_list(value) do
    value
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_string_list(value, default) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> normalize_string_list(default)
  end

  defp normalize_string_list(_value, default), do: normalize_string_list(default, [])

  defp optional_arg(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value ->
        value
    end
  end

  defp config do
    Application.get_env(:serviceradar_web_ng, :native_addon_import, [])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
