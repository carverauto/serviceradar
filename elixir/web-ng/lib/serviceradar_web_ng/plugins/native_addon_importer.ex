defmodule ServiceRadarWebNG.Plugins.NativeAddonImporter do
  @moduledoc """
  Imports a first-party native add-on from a trusted GitHub release into a staged
  `AddonPackage` (issue 3425, add-native-addon-build-signing §4.1). The web-ng
  counterpart to `FirstPartyImporter`: it owns transport + discovery trust (OCI +
  Cosign) and delegates per-arch artifact trust + persistence to the core
  `ServiceRadar.Plugins.NativeAddonImporter`.

  Flow: resolve the repo + release tag, fetch `serviceradar-native-addon-index.json`,
  find the entry, fetch + Cosign-verify the OCI manifest, then — since the index
  entry already carries each per-arch `tarball_digest`/`signature_digest` and the
  `bundle_digest` — assert those are layers of the Cosign-verified manifest and pull
  the blobs by digest (content-addressed). The bundle's `addon.yaml` +
  `config.schema.json` and the assembled per-arch artifacts go to
  `Core.import_entry/4`, which verifies each tarball's agent-release ed25519
  signature, mirrors it (`NativeAddonArtifactMirror`), and creates the staged
  `AddonPackage`. All HTTP/OCI/Cosign/URL transport is the shared
  `FirstPartyReleaseClient`.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.DisplayContract
  alias ServiceRadar.Plugins.NativeAddonArtifactMirror
  alias ServiceRadar.Plugins.NativeAddonImporter, as: Core
  alias ServiceRadar.Plugins.RetiredNativeAddons
  alias ServiceRadarWebNG.Plugins.FirstPartyReleaseClient, as: Client

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @default_index_asset_name "serviceradar-native-addon-index.json"
  @default_recent_release_limit 10
  @max_bundle_bytes 64 * 1024 * 1024
  @max_artifact_bytes 256 * 1024 * 1024

  @spec list_recent_addons(map(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def list_recent_addons(attrs \\ %{}, limit \\ @default_recent_release_limit)

  def list_recent_addons(attrs, limit) when is_map(attrs) do
    with {:ok, summary} <- list_recent_addons_with_summary(attrs, limit) do
      {:ok, summary.addons}
    end
  end

  def list_recent_addons(_attrs, _limit), do: {:error, :invalid_attributes}

  @spec list_recent_addons_with_summary(map(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def list_recent_addons_with_summary(attrs \\ %{}, limit \\ @default_recent_release_limit)

  def list_recent_addons_with_summary(attrs, limit) when is_map(attrs) do
    with {:ok, repo} <- import_repo(attrs),
         {:ok, releases} <- Client.fetch_recent_releases(repo, limit) do
      index_name = index_asset_name(attrs)

      releases
      |> Enum.reduce_while({:ok, %{addons: [], indexed_releases: 0}}, fn release, {:ok, acc} ->
        if Client.release_asset_present?(release, index_name) do
          case release_addons(repo, release, attrs) do
            {:ok, addons} ->
              {:cont, {:ok, %{acc | addons: acc.addons ++ addons, indexed_releases: acc.indexed_releases + 1}}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        else
          {:cont, {:ok, acc}}
        end
      end)
      |> case do
        {:ok, summary} ->
          {:ok,
           Map.merge(summary, %{
             addons: Enum.reject(summary.addons, &RetiredNativeAddons.retired?(&1.addon_id)),
             scanned_releases: length(releases),
             index_asset_name: index_name,
             repo_url: repo.repo_url
           })}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def list_recent_addons_with_summary(_attrs, _limit), do: {:error, :invalid_attributes}

  @doc """
  Lists native add-ons from one exact GitHub release.

  Automatic synchronization uses this path so the catalog is anchored to the
  immutable ServiceRadar release currently running, rather than depending on the
  ordering or completeness of GitHub's recent-release feed.
  """
  @spec list_release_addons(map(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_release_addons(attrs, release_tag) when is_map(attrs) do
    with {:ok, repo} <- import_repo(attrs),
         {:ok, release_tag} <-
           Client.require_value(release_tag, "Release tag is required"),
         {:ok, release} <- Client.fetch_release(repo, release_tag),
         {:ok, index} <- fetch_release_index(repo, release, attrs) do
      addons =
        index
        |> index_entries()
        |> Enum.map(&summarize_entry(repo, release, &1))
        |> Enum.reject(fn addon ->
          is_nil(addon) or RetiredNativeAddons.retired?(addon.addon_id)
        end)

      {:ok, addons}
    end
  end

  def list_release_addons(_attrs, _release_tag), do: {:error, :invalid_attributes}

  @doc """
  Discovers native add-ons for unattended sync.

  Uses `ServiceRadarWebNG.Plugins.FirstPartyReleaseClient.resolve_catalog/3`
  for feed selection. The returned filter tag is the requested tag on an exact
  hit and `nil` for recent releases, so callers do not re-filter fallback entries
  by the missing tag. The settings UI sentinel keeps an exact-only lookup; see
  `ServiceRadarWebNG.Plugins.FirstPartyReleaseClient.admin_all_releases_sentinel/0`.
  """
  @spec list_addons_for_sync(map(), keyword()) ::
          {:ok, [map()], String.t() | nil} | {:error, term()}
  def list_addons_for_sync(attrs, opts \\ [])

  def list_addons_for_sync(attrs, opts) when is_map(attrs) and is_list(opts) do
    limit = Keyword.get(opts, :limit, @default_recent_release_limit)
    release_tag = Keyword.get(opts, :release_tag)

    if release_tag == Client.admin_all_releases_sentinel() do
      with {:ok, addons} <- list_release_addons(attrs, release_tag) do
        {:ok, addons, release_tag}
      end
    else
      case Client.resolve_catalog(
             release_tag,
             fn tag -> list_release_addons(attrs, tag) end,
             fn -> list_recent_addons(attrs, limit) end
           ) do
        {:ok, addons, :exact} -> {:ok, addons, release_tag}
        {:ok, addons, :recent} -> {:ok, addons, nil}
        {:error, _} = error -> error
      end
    end
  end

  def list_addons_for_sync(_attrs, _opts), do: {:error, :invalid_attributes}

  @spec import(map()) :: {:ok, AddonPackage.t()} | {:error, term()}
  def import(attrs) when is_map(attrs) do
    with {:ok, package, _disposition} <- import_with_disposition(attrs) do
      {:ok, package}
    end
  end

  def import(_attrs), do: {:error, :invalid_attributes}

  @spec import_with_disposition(map()) ::
          {:ok, AddonPackage.t(), Core.import_disposition()} | {:error, term()}
  def import_with_disposition(attrs) when is_map(attrs) do
    with {:ok, repo} <- import_repo(attrs),
         {:ok, release_tag} <-
           Client.require_value(fetch_value(attrs, [:release_tag, "release_tag"]), "Release tag is required"),
         {:ok, requested_addon_id} <- optional_string(fetch_value(attrs, [:addon_id, "addon_id"])),
         {:ok, requested_version} <- optional_string(fetch_value(attrs, [:version, "version"])),
         {:ok, public_key} <- release_public_key(),
         {:ok, release} <- Client.fetch_release(repo, release_tag),
         {:ok, index} <- fetch_release_index(repo, release, attrs),
         {:ok, entry} <- find_entry(index, requested_addon_id, requested_version),
         :ok <- ensure_not_retired_entry(entry),
         {:ok, fetched} <- fetch_artifact(repo, entry),
         {:ok, manifest, config_schema, contracts} <- extract_manifest(fetched.bundle) do
      Core.import_entry_with_disposition(manifest, entry, fetched.artifacts,
        public_key: public_key,
        mirror: build_mirror(addon_id(manifest, entry), version(manifest, entry)),
        actor: SystemActor.system(:native_addon_importer),
        config_schema: config_schema,
        display_contracts: contracts.valid,
        display_contract_errors: contracts.errors,
        release_tag: release_tag,
        replace_existing: replace_existing?(attrs)
      )
    end
  end

  def import_with_disposition(_attrs), do: {:error, :invalid_attributes}

  defp replace_existing?(attrs) do
    fetch_value(attrs, [:replace_existing, "replace_existing"]) in [true, "true"]
  end

  defp ensure_not_retired_entry(entry) do
    addon_id = entry_string(entry, "addon_id")

    if RetiredNativeAddons.retired?(addon_id) do
      {:error, {:retired_native_addon, addon_id, RetiredNativeAddons.reason(addon_id)}}
    else
      :ok
    end
  end

  # --- repo + index -------------------------------------------------------------

  defp import_repo(attrs) do
    repo_url = fetch_value(attrs, [:repo_url, "repo_url"]) || configured_repo_url()
    Client.parse_repo_url(repo_url)
  end

  defp configured_repo_url do
    config = Application.get_env(:serviceradar_web_ng, :native_addon_import, [])
    Keyword.get(config, :repo_url, Client.default_repo_url())
  end

  defp index_asset_name(attrs) do
    fetch_value(attrs, [:index_asset_name, "index_asset_name"]) ||
      Keyword.get(
        Application.get_env(:serviceradar_web_ng, :native_addon_import, []),
        :index_asset_name,
        @default_index_asset_name
      )
  end

  defp fetch_release_index(repo, release, attrs) do
    with {:ok, asset} <- Client.fetch_release_asset(release, index_asset_name(attrs)),
         {:ok, body} <- Client.fetch_binary_asset(repo, asset) do
      Client.decode_index(body)
    end
  end

  defp release_addons(repo, release, attrs) do
    tag = Client.normalize_string(Map.get(release, "tag_name"))

    cond do
      is_nil(tag) ->
        {:ok, []}

      not Client.release_asset_present?(release, index_asset_name(attrs)) ->
        {:ok, []}

      true ->
        with {:ok, index} <- fetch_release_index(repo, release, attrs) do
          entries =
            index
            |> index_entries()
            |> Enum.map(&summarize_entry(repo, release, &1))
            |> Enum.reject(&is_nil/1)

          {:ok, entries}
        end
    end
  end

  defp index_entries(index) when is_map(index) do
    index
    |> Map.get("addons", Map.get(index, :addons, []))
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  end

  defp summarize_entry(repo, release, entry) do
    addon_id = entry_string(entry, "addon_id")
    version = entry_string(entry, "version")

    if addon_id in [nil, ""] or version in [nil, ""] do
      nil
    else
      %{
        addon_id: addon_id,
        name: entry_string(entry, "name") || addon_id,
        version: version,
        release_tag: Client.normalize_string(Map.get(release, "tag_name")),
        release_url: Client.normalize_string(Map.get(release, "html_url")),
        repo_url: repo.repo_url,
        oci_ref: entry_string(entry, "oci_ref"),
        oci_digest: entry_string(entry, "oci_digest"),
        bundle_digest: entry_string(entry, "bundle_digest"),
        artifacts: List.wrap(entry_value(entry, "artifacts")),
        import_ready?: import_ready_entry?(entry)
      }
    end
  end

  defp import_ready_entry?(entry) do
    entry_string(entry, "oci_ref") not in [nil, ""] and
      entry_string(entry, "oci_digest") not in [nil, ""] and
      entry_string(entry, "bundle_digest") not in [nil, ""] and
      List.wrap(entry_value(entry, "artifacts")) != []
  end

  defp find_entry(index, nil, nil) do
    case index_entries(index) do
      [entry] -> {:ok, entry}
      [] -> {:error, :addon_not_found}
      _entries -> {:error, :addon_selection_required}
    end
  end

  defp find_entry(index, addon_id, version) do
    entry =
      Enum.find(index_entries(index), fn entry ->
        (is_nil(addon_id) or entry_string(entry, "addon_id") == addon_id) and
          (is_nil(version) or entry_string(entry, "version") == version)
      end)

    case entry do
      nil -> {:error, :addon_not_found}
      entry -> {:ok, entry}
    end
  end

  # --- OCI fetch (bundle + per-arch artifacts, bound to the cosign-verified manifest) ---

  defp fetch_artifact(repo, entry) do
    with {:ok, ref} <- Client.parse_oci_ref(entry_string(entry, "oci_ref")),
         :ok <- Client.validate_oci_registry(ref.registry),
         {:ok, manifest, manifest_digest} <- Client.fetch_oci_manifest(repo, ref),
         :ok <- Client.verify_declared_digest(entry_string(entry, "oci_digest"), manifest_digest),
         :ok <- Client.verify_cosign_signature(entry_string(entry, "oci_ref"), manifest_digest),
         layer_digests = manifest_layer_digests(manifest),
         {:ok, bundle} <-
           fetch_layer_blob(repo, ref, entry_string(entry, "bundle_digest"), layer_digests, @max_bundle_bytes),
         {:ok, artifacts} <- fetch_per_arch_artifacts(repo, ref, entry, layer_digests) do
      {:ok, %{bundle: bundle, artifacts: artifacts, oci_digest: manifest_digest}}
    end
  end

  defp manifest_layer_digests(manifest) do
    manifest
    |> Map.get("layers", [])
    |> Enum.map(&Map.get(&1, "digest"))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  # Fetch a blob by digest only after asserting it is a layer of the cosign-verified
  # manifest, so a tampered index can't point the agent at an unsigned blob.
  defp fetch_layer_blob(repo, ref, digest, layer_digests, max_bytes) do
    cond do
      digest in [nil, ""] ->
        {:error, :artifact_reference_required}

      not MapSet.member?(layer_digests, digest) ->
        {:error, {:digest_not_in_manifest, digest}}

      true ->
        case Client.fetch_oci_blob(repo, ref, digest) do
          {:ok, blob} when byte_size(blob) > max_bytes ->
            {:error, :artifact_too_large}

          {:ok, blob} ->
            # Manifest membership only proves the *declared* layer set; re-hash the
            # returned bytes against the digest so a tampering/buggy registry can't
            # swap the content. The per-arch tarball is also covered by the core's
            # sha256 + ed25519, but the bundle (addon.yaml/config.schema.json) is
            # otherwise unsigned, so this is its only byte-level integrity gate.
            if Client.digest_matches?(digest, blob) do
              {:ok, blob}
            else
              {:error, {:blob_digest_mismatch, digest}}
            end

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp fetch_per_arch_artifacts(repo, ref, entry, layer_digests) do
    artifacts = List.wrap(entry_value(entry, "artifacts"))

    if artifacts == [] do
      {:error, :artifact_reference_required}
    else
      artifacts
      |> Enum.reduce_while({:ok, []}, fn artifact, {:ok, acc} ->
        case fetch_one_artifact(repo, ref, artifact, layer_digests) do
          {:ok, fetched} -> {:cont, {:ok, [fetched | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, fetched} -> {:ok, Enum.reverse(fetched)}
        error -> error
      end
    end
  end

  defp fetch_one_artifact(repo, ref, artifact, layer_digests) when is_map(artifact) do
    os = entry_string(artifact, "os")
    arch = entry_string(artifact, "arch")
    signature_digest = entry_string(artifact, "signature_digest")

    with true <- is_binary(os) and is_binary(arch) and os != "" and arch != "",
         {:ok, tarball} <-
           fetch_layer_blob(repo, ref, entry_string(artifact, "tarball_digest"), layer_digests, @max_artifact_bytes),
         {:ok, sig_blob} <-
           fetch_layer_blob(repo, ref, signature_digest, layer_digests, @max_artifact_bytes),
         signature when is_binary(signature) <- Client.normalize_string(sig_blob),
         sha256 when is_binary(sha256) <- entry_string(artifact, "tarball_sha256") do
      {:ok,
       %{
         os: os,
         arch: arch,
         tarball: tarball,
         signature: signature,
         signature_digest: signature_digest,
         sha256: sha256
       }}
    else
      false -> {:error, :invalid_artifact_platform}
      nil -> {:error, :invalid_artifact_metadata}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_one_artifact(_repo, _ref, _artifact, _layer_digests), do: {:error, :invalid_artifact_metadata}

  # --- bundle manifest extraction ----------------------------------------------

  defp extract_manifest(bundle) when is_binary(bundle) do
    with {:ok, files} <- extract_bundle(bundle),
         {:ok, addon_yaml} <- fetch_bundle_file(files, "addon.yaml"),
         {:ok, manifest} <- parse_yaml(addon_yaml) do
      {:ok, manifest, optional_bundle_json(files, "config.schema.json"), extract_display_contracts(files)}
    end
  end

  defp extract_manifest(_bundle), do: {:error, :invalid_bundle}

  # `normalize_zip_name/1` flattens bundle entries to their basename, so a
  # contract shipped at `display/dns_activity.display.json` arrives here as
  # `dns_activity.display.json`. Match on the suffix rather than the directory.
  #
  # Validation happens here, at import, so a stored contract is always known-good
  # data; a contract this release refuses is dropped and reported rather than
  # failing the whole signed add-on over a UI file (`DisplayContract.partition/1`).
  defp extract_display_contracts(files) do
    {valid, errors} =
      files
      |> Enum.filter(fn {name, payload} ->
        is_binary(name) and is_binary(payload) and String.ends_with?(name, ".display.json")
      end)
      |> Map.new()
      |> DisplayContract.partition()

    %{valid: valid, errors: errors}
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp extract_bundle(bundle) do
    path = Path.join(System.tmp_dir!(), "sr-addon-bundle-#{System.unique_integer([:positive])}.zip")

    try do
      File.write!(path, bundle)

      case :zip.extract(String.to_charlist(path), [:memory]) do
        {:ok, files} -> {:ok, Map.new(files, fn {name, payload} -> {normalize_zip_name(name), payload} end)}
        {:error, reason} -> {:error, {:invalid_bundle, reason}}
      end
    after
      File.rm(path)
    end
  end

  defp normalize_zip_name(name) when is_list(name), do: name |> to_string() |> normalize_zip_name()
  defp normalize_zip_name(name) when is_binary(name), do: name |> String.trim_leading("/") |> Path.basename()
  defp normalize_zip_name(_name), do: ""

  defp fetch_bundle_file(files, name) do
    case Map.fetch(files, name) do
      {:ok, payload} when is_binary(payload) -> {:ok, payload}
      _ -> {:error, {:bundle_missing, name}}
    end
  end

  defp parse_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, _other} -> {:error, :invalid_addon_manifest}
      {:error, _reason} -> {:error, :invalid_addon_manifest}
    end
  end

  defp optional_bundle_json(files, name) do
    case Map.get(files, name) do
      payload when is_binary(payload) ->
        case Jason.decode(payload) do
          {:ok, %{} = map} -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  # --- helpers ------------------------------------------------------------------

  defp release_public_key do
    raw =
      Application.get_env(:serviceradar_web_ng, :native_addon_release_public_key) ||
        System.get_env("SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY")

    with value when is_binary(value) and value != "" <- raw,
         {:ok, key} when byte_size(key) == 32 <- Core.decode_key_or_signature(String.trim(value)) do
      {:ok, key}
    else
      _ -> {:error, :release_public_key_unavailable}
    end
  end

  # The datasvc object-store upload is injectable so the importer is testable
  # without a gRPC channel; production leaves `:native_addon_artifact_upload` unset
  # and the mirror falls back to its default upload.
  defp build_mirror(addon_id, version) do
    opts =
      case Application.get_env(:serviceradar_web_ng, :native_addon_artifact_upload) do
        upload when is_function(upload, 3) -> [upload_object: upload]
        _ -> []
      end

    NativeAddonArtifactMirror.mirror_fun(addon_id, version, opts)
  end

  defp addon_id(manifest, entry), do: Client.normalize_string(Map.get(manifest, "id")) || entry_string(entry, "addon_id")

  defp version(manifest, entry),
    do: Client.normalize_string(Map.get(manifest, "version")) || entry_string(entry, "version")

  defp fetch_value(attrs, keys), do: Enum.find_value(keys, &Map.get(attrs, &1))

  defp optional_string(nil), do: {:ok, nil}
  defp optional_string(""), do: {:ok, nil}

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed -> {:ok, trimmed}
    end
  end

  defp optional_string(_value), do: {:error, :invalid_selection}

  defp entry_string(entry, key), do: Client.normalize_string(entry_value(entry, key))

  defp entry_value(entry, key) when is_map(entry), do: Map.get(entry, key)
  defp entry_value(_entry, _key), do: nil
end
