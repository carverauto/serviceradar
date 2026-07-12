defmodule ServiceRadarWebNG.Plugins.NativeAddonSync do
  @moduledoc """
  Authoritative import-or-reuse policy for first-party native add-ons.

  Both scheduled synchronization and authenticated admin imports delegate here so
  source ownership, artifact integrity, repair, and approval semantics cannot
  diverge between entry points.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.NativeAddonArtifactMirror
  alias ServiceRadar.Plugins.RetiredNativeAddons
  alias ServiceRadarWebNG.Plugins.NativeAddonImporter

  require Ash.Query

  @type sync_result ::
          {:imported, AddonPackage.t()}
          | {:skipped, AddonPackage.t()}
          | {:error, term()}

  @spec candidates([map()], keyword()) :: [map()]
  def candidates(addons, opts \\ []) when is_list(addons) do
    release_tag = Keyword.get(opts, :release_tag)
    addon_ids = Keyword.get(opts, :addon_ids, [])

    addons
    |> maybe_filter_release_tag(release_tag)
    |> Enum.filter(
      &(Map.get(&1, :import_ready?) and selected_addon?(&1, addon_ids) and
          not RetiredNativeAddons.retired?(&1.addon_id))
    )
    |> dedupe_native_addon_versions()
  end

  @spec import_or_reuse(map(), keyword()) :: sync_result()
  def import_or_reuse(addon, opts \\ []) when is_map(addon) do
    case existing_package(addon.addon_id, addon.version, opts) do
      {:ok, nil} ->
        sync_import(addon, opts)

      {:ok, %AddonPackage{} = package} ->
        cond do
          source_conflict?(package, addon) ->
            {:error, source_conflict(package, addon)}

          reusable_package?(package, addon) ->
            {:skipped, package}

          true ->
            sync_import(addon, opts)
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec summary([map()], [{map(), sync_result()}]) :: map()
  def summary(discovered, results) do
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

  defp existing_package(addon_id, version, opts) do
    read_opts = ash_read_opts(opts)

    AddonPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(addon_id == ^addon_id and version == ^version)
    |> Ash.read_one(read_opts)
  end

  defp ash_read_opts(opts) do
    case {Keyword.get(opts, :scope), Keyword.get(opts, :actor)} do
      {scope, actor} when not is_nil(scope) and not is_nil(actor) -> [scope: scope, actor: actor]
      {scope, _actor} when not is_nil(scope) -> [scope: scope]
      {_scope, actor} when not is_nil(actor) -> [actor: actor]
      _ -> [actor: SystemActor.system(:native_addon_sync)]
    end
  end

  defp sync_import(addon, opts) do
    case NativeAddonImporter.import_with_disposition(import_attrs(addon)) do
      {:ok, package, :created} ->
        with {:ok, package} <- maybe_approve(package, opts) do
          {:imported, package}
        end

      {:ok, package, :repaired} ->
        {:imported, package}

      {:ok, package, :reused} ->
        {:skipped, package}

      {:error, _reason} = error ->
        error
    end
  end

  defp import_attrs(addon) do
    %{
      repo_url: addon.repo_url,
      release_tag: addon.release_tag,
      addon_id: addon.addon_id,
      version: addon.version
    }
  end

  defp maybe_approve(%AddonPackage{addon_id: addon_id, status: :staged} = package, opts) do
    if addon_id in Keyword.get(opts, :auto_approve_addon_ids, []) do
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

  defp maybe_approve(%AddonPackage{} = package, _opts), do: {:ok, package}

  defp reusable_package?(%AddonPackage{} = package, addon) do
    package.source_type == :first_party and source_matches?(package, addon) and
      package.verification_status == "verified" and is_nil(package.verification_error) and
      artifact_contract_matches?(
        package.addon_id,
        package.version,
        package.artifacts,
        addon.artifacts
      )
  end

  defp source_conflict?(%AddonPackage{source_type: source_type}, _addon) when source_type != :first_party, do: true

  defp source_conflict?(%AddonPackage{} = package, addon) do
    populated_source_disagrees?(package.source_oci_ref, addon.oci_ref, &normalize_source_ref/1) or
      populated_source_disagrees?(
        package.source_oci_digest,
        addon.oci_digest,
        &normalize_source_digest/1
      )
  end

  defp source_conflict(%AddonPackage{} = package, addon) do
    reason =
      if package.source_type == :first_party,
        do: :oci_source_mismatch,
        else: :source_type_owned

    {:native_addon_version_source_conflict,
     %{
       reason: reason,
       addon_id: addon.addon_id,
       version: addon.version,
       existing_source_type: package.source_type,
       existing_oci_ref: package.source_oci_ref,
       existing_oci_digest: package.source_oci_digest,
       discovered_oci_ref: addon.oci_ref,
       discovered_oci_digest: addon.oci_digest
     }}
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
end
