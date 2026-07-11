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
  alias ServiceRadar.Plugins.NativeAddonArtifactMirror
  alias ServiceRadar.Plugins.RetiredNativeAddons
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport
  alias ServiceRadarWebNG.Plugins.NativeAddonImporter

  require Ash.Query
  require Logger

  @default_release_limit 10
  @default_reschedule_seconds 3_600
  @failure_reason_limit 512
  @queued_unique [period: :infinity, states: [:available, :scheduled, :retryable]]
  @manual_unique [period: :infinity, states: [:available, :retryable]]

  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if check_existing_job() do
        {:ok, :already_scheduled}
      else
        %{} |> queued_job(schedule_in: 60) |> ObanSupport.safe_insert()
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

        Enum.each(summary.failed, &log_package_failure/1)

        :ok

      {:error, reason} ->
        Logger.warning("First-party native add-on sync failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp schedule_next do
    if auto_sync_enabled?() and ObanSupport.available?() do
      case ObanSupport.safe_insert(queued_job(%{}, schedule_in: reschedule_seconds())) do
        {:ok, %Oban.Job{}} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to schedule the next first-party native add-on sync",
            reason: bounded_failure_reason(reason)
          )
      end
    end

    :ok
  end

  defp check_existing_job do
    query =
      from(j in Oban.Job,
        where: j.worker == ^inspect(__MODULE__),
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
            repair_addon(addon)
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

  defp repair_addon(addon) do
    import_attrs = %{
      repo_url: addon.repo_url,
      release_tag: addon.release_tag,
      addon_id: addon.addon_id,
      version: addon.version
    }

    with {:ok, package} <- NativeAddonImporter.import(import_attrs) do
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
      artifact_contract_matches?(
        package.addon_id,
        package.version,
        package.artifacts,
        addon.artifacts
      )
  end

  defp source_conflict?(%AddonPackage{} = package, addon) do
    populated_source_disagrees?(package.source_oci_ref, addon.oci_ref, &normalize_source_ref/1) or
      populated_source_disagrees?(
        package.source_oci_digest,
        addon.oci_digest,
        &normalize_source_digest/1
      )
  end

  defp source_matches?(%AddonPackage{} = package, addon) do
    existing_ref = normalize_source_ref(package.source_oci_ref)
    existing_digest = normalize_source_digest(package.source_oci_digest)

    not is_nil(existing_ref) and not is_nil(existing_digest) and
      existing_ref == normalize_source_ref(addon.oci_ref) and
      existing_digest == normalize_source_digest(addon.oci_digest)
  end

  defp artifact_contract_matches?(addon_id, version, persisted, declared)
       when is_binary(addon_id) and is_binary(version) and is_map(persisted) and is_list(declared) and declared != [] do
    with {:ok, declared_contracts} <- declared_artifact_contracts(declared),
         {:ok, persisted_contracts} <-
           persisted_artifact_contracts(addon_id, version, persisted) do
      declared_platforms = declared_contracts |> Map.keys() |> MapSet.new()
      persisted_platforms = persisted_contracts |> Map.keys() |> MapSet.new()

      declared_platforms == persisted_platforms and
        Enum.all?(declared_contracts, fn {platform, declared_contract} ->
          persisted_contract_matches?(Map.get(persisted_contracts, platform), declared_contract)
        end)
    else
      _ -> false
    end
  end

  defp artifact_contract_matches?(_addon_id, _version, _persisted, _declared), do: false

  defp declared_artifact_contracts(artifacts) do
    Enum.reduce_while(artifacts, {:ok, %{}}, fn artifact, {:ok, contracts} ->
      with {:ok, platform} <- artifact_platform(artifact),
           false <- Map.has_key?(contracts, platform),
           sha256 when is_binary(sha256) <- normalize_sha256(map_value(artifact, :tarball_sha256)),
           tarball_digest when tarball_digest == "sha256:" <> sha256 <-
             normalize_digest(map_value(artifact, :tarball_digest)),
           signature_digest when is_binary(signature_digest) <-
             normalize_digest(map_value(artifact, :signature_digest)) do
        contract = %{sha256: sha256, signature_digest: signature_digest}
        {:cont, {:ok, Map.put(contracts, platform, contract)}}
      else
        _ -> {:halt, {:error, :invalid_declared_artifact_contract}}
      end
    end)
  end

  defp persisted_artifact_contracts(addon_id, version, artifacts) do
    Enum.reduce_while(artifacts, {:ok, %{}}, fn {platform_key, artifact}, {:ok, contracts} ->
      case persisted_artifact_contract(addon_id, version, platform_key, artifact) do
        {:ok, platform, contract} ->
          if Map.has_key?(contracts, platform) do
            {:halt, {:error, :duplicate_persisted_artifact_platform}}
          else
            {:cont, {:ok, Map.put(contracts, platform, contract)}}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp persisted_artifact_contract(addon_id, version, platform_key, artifact) when is_map(artifact) do
    platform = normalize_platform(platform_key)
    object_key = normalize_string(map_value(artifact, :object_key))
    sha256 = normalize_sha256(map_value(artifact, :sha256))
    signature = normalize_string(map_value(artifact, :signature))
    signature_digest_result = persisted_signature_digest(artifact)

    with platform when is_binary(platform) <- platform,
         object_key when is_binary(object_key) <- object_key,
         sha256 when is_binary(sha256) <- sha256,
         signature when is_binary(signature) <- signature,
         {:ok, signature_digest} <- signature_digest_result do
      [os, arch] = String.split(platform, "/", parts: 2)
      expected_object_key = NativeAddonArtifactMirror.object_key(addon_id, version, os, arch, sha256)

      if object_key == expected_object_key do
        {:ok, platform,
         %{
           sha256: sha256,
           signature_digest: signature_digest,
           canonical_signature_digest: digest(signature <> "\n")
         }}
      else
        {:error, :unexpected_persisted_artifact_object_key}
      end
    else
      _ -> {:error, :invalid_persisted_artifact_contract}
    end
  end

  defp persisted_artifact_contract(_addon_id, _version, _platform_key, _artifact),
    do: {:error, :invalid_persisted_artifact_contract}

  defp persisted_contract_matches?(
         %{
           sha256: sha256,
           signature_digest: persisted_signature_digest,
           canonical_signature_digest: canonical_signature_digest
         },
         %{sha256: sha256, signature_digest: declared_signature_digest}
       ) do
    canonical_signature_digest == declared_signature_digest and
      persisted_signature_digest in [nil, declared_signature_digest]
  end

  defp persisted_contract_matches?(_persisted, _declared), do: false

  defp persisted_signature_digest(artifact) do
    case normalize_string(map_value(artifact, :signature_digest)) do
      nil ->
        {:ok, nil}

      value ->
        case normalize_digest(value) do
          nil -> {:error, :invalid_signature_digest}
          digest -> {:ok, digest}
        end
    end
  end

  defp artifact_platform(artifact) when is_map(artifact) do
    with os when is_binary(os) <- normalize_platform_segment(map_value(artifact, :os)),
         arch when is_binary(arch) <- normalize_platform_segment(map_value(artifact, :arch)) do
      {:ok, "#{os}/#{arch}"}
    else
      _ -> {:error, :invalid_artifact_platform}
    end
  end

  defp artifact_platform(_artifact), do: {:error, :invalid_artifact_platform}

  defp normalize_platform(value) do
    case normalize_string(value) do
      value when is_binary(value) ->
        case String.split(value, "/", parts: 2) do
          [os, arch] ->
            with os when is_binary(os) <- normalize_platform_segment(os),
                 arch when is_binary(arch) <- normalize_platform_segment(arch) do
              "#{os}/#{arch}"
            else
              _ -> nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp normalize_platform_segment(value) do
    case normalize_string(value) do
      value when is_binary(value) ->
        value = String.downcase(value)
        if Regex.match?(~r/\A[a-z0-9][a-z0-9._-]*\z/, value), do: value

      _ ->
        nil
    end
  end

  defp normalize_sha256(value) do
    case normalize_string(value) do
      value when is_binary(value) ->
        value = String.downcase(value)

        if Regex.match?(~r/\A[0-9a-f]{64}\z/, value), do: value

      _ ->
        nil
    end
  end

  defp normalize_digest(value) do
    case normalize_source_digest(value) do
      "sha256:" <> sha256 = digest ->
        if normalize_sha256(sha256), do: digest

      _ ->
        nil
    end
  end

  defp normalize_source_ref(value), do: normalize_string(value)

  defp normalize_source_digest(value) do
    case normalize_string(value) do
      value when is_binary(value) -> String.downcase(value)
      _ -> nil
    end
  end

  defp populated_source_disagrees?(existing, discovered, normalize) do
    case normalize_string(existing) do
      nil -> false
      _existing -> normalize.(existing) != normalize.(discovered)
    end
  end

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_string(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_string()
  defp normalize_string(_value), do: nil

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, Atom.to_string(key)) || Map.get(map, key)
  end

  defp digest(value) do
    "sha256:" <> (:sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower))
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

  defp log_package_failure(failure) do
    Logger.warning("First-party native add-on package sync failed",
      addon_id: failure.addon_id,
      addon_version: failure.version,
      release_tag: failure.release_tag,
      reason: bounded_failure_reason(failure.error)
    )
  end

  defp bounded_failure_reason(reason) do
    reason
    |> inspect(limit: 20, printable_limit: @failure_reason_limit, width: 120)
    |> String.slice(0, @failure_reason_limit)
  end

  defp queued_job(args, opts) do
    new(args, Keyword.put(opts, :unique, @queued_unique))
  end

  defp manual_job(args, opts \\ []) do
    new(args, Keyword.put(opts, :unique, @manual_unique))
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
