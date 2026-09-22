defmodule ServiceRadarWebNG.Plugins.FirstPartyImporter do
  @moduledoc """
  Discovers and imports first-party Wasm plugin bundles from GitHub Releases.

  HTTP/OCI/Cosign/URL transport is the shared `FirstPartyReleaseClient`
  (imported below); this module keeps only the Wasm-bundle-specific discovery,
  verification, and result-shaping logic. The `default_repo_url/0` import is
  excepted so this module can re-export it as its own public accessor.
  """

  import ServiceRadarWebNG.Plugins.FirstPartyReleaseClient, except: [default_repo_url: 0]

  alias ServiceRadar.Plugins.DisplayContract
  alias ServiceRadar.Plugins.Manifest
  alias ServiceRadarWebNG.Plugins.FirstPartyReleaseClient
  alias ServiceRadarWebNG.Plugins.Storage
  alias ServiceRadarWebNG.Plugins.UploadSignature

  @default_index_asset_name "serviceradar-wasm-plugin-index.json"
  @default_recent_release_limit 10
  # The shared client caps recent-release scans at 50 (for native add-ons); the
  # Wasm importer has always scanned at most 20, so clamp to preserve that ceiling.
  @max_recent_release_scan 20
  @bundle_media_type "application/zip"
  @upload_signature_media_type "application/vnd.serviceradar.wasm-plugin.upload-signature.v1+json"
  @max_bundle_bytes 64 * 1024 * 1024
  @max_uncompressed_bundle_bytes 80 * 1024 * 1024
  @max_bundle_entries 128
  @max_resource_bytes 4 * 1024 * 1024

  @spec default_index_asset_name() :: String.t()
  def default_index_asset_name, do: @default_index_asset_name

  @spec default_repo_url() :: String.t()
  def default_repo_url, do: FirstPartyReleaseClient.default_repo_url()

  @spec list_recent_plugins(map(), pos_integer()) :: {:ok, [map()]} | {:error, String.t()}
  def list_recent_plugins(attrs \\ %{}, limit \\ @default_recent_release_limit)

  def list_recent_plugins(attrs, limit) when is_map(attrs) do
    with {:ok, summary} <- list_recent_plugins_with_summary(attrs, limit) do
      {:ok, summary.plugins}
    end
  end

  def list_recent_plugins(_attrs, _limit), do: {:error, "Plugin import settings are invalid"}

  @spec list_recent_plugins_with_summary(map(), pos_integer()) :: {:ok, map()} | {:error, String.t()}
  def list_recent_plugins_with_summary(attrs \\ %{}, limit \\ @default_recent_release_limit)

  def list_recent_plugins_with_summary(attrs, limit) when is_map(attrs) do
    with {:ok, repo} <- import_repo(attrs),
         {:ok, releases} <- fetch_recent_releases(repo, clamp_recent_release_limit(limit)) do
      index_name = index_asset_name(attrs)

      releases
      |> Enum.reduce_while({:ok, %{plugins: [], indexed_releases: 0}}, fn release, {:ok, acc} ->
        if release_asset_present?(release, index_name) do
          case release_plugins(repo, release, attrs) do
            {:ok, plugins} ->
              {:cont, {:ok, %{acc | plugins: acc.plugins ++ plugins, indexed_releases: acc.indexed_releases + 1}}}

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
             scanned_releases: length(releases),
             index_asset_name: index_name,
             repo_url: repo.repo_url
           })}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def list_recent_plugins_with_summary(_attrs, _limit), do: {:error, "Plugin import settings are invalid"}

  @doc """
  Lists Wasm plugins from one exact GitHub release.

  Automatic synchronization uses this path so the catalog is anchored to the
  immutable ServiceRadar release currently running, rather than depending on the
  ordering or completeness of GitHub's recent-release feed.
  """
  @spec list_release_plugins(map(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_release_plugins(attrs, release_tag) when is_map(attrs) do
    with {:ok, repo} <- import_repo(attrs),
         {:ok, release_tag} <- require_value(release_tag, "Release tag is required"),
         {:ok, release} <- fetch_release(repo, release_tag),
         {:ok, index} <- fetch_release_index(repo, release, attrs) do
      plugins =
        index
        |> index_entries()
        |> Enum.map(&summarize_entry(repo, release, &1))
        |> Enum.reject(&is_nil/1)

      {:ok, plugins}
    end
  end

  def list_release_plugins(_attrs, _release_tag), do: {:error, "Plugin import settings are invalid"}

  @doc """
  Discovers Wasm plugins for unattended sync.

  Uses `FirstPartyReleaseClient.resolve_catalog/3` for feed selection. The
  returned filter tag is the requested tag on an exact hit and `nil` for recent
  releases, so callers do not re-filter fallback entries by the missing tag.
  The settings UI sentinel keeps an exact-only lookup; see
  `FirstPartyReleaseClient.admin_all_releases_sentinel/0`.
  """
  @spec list_plugins_for_sync(map(), keyword()) ::
          {:ok, [map()], String.t() | nil} | {:error, term()}
  def list_plugins_for_sync(attrs, opts \\ [])

  def list_plugins_for_sync(attrs, opts) when is_map(attrs) and is_list(opts) do
    limit = Keyword.get(opts, :limit, @default_recent_release_limit)
    release_tag = Keyword.get(opts, :release_tag)

    if release_tag == FirstPartyReleaseClient.admin_all_releases_sentinel() do
      with {:ok, plugins} <- list_release_plugins(attrs, release_tag) do
        {:ok, plugins, release_tag}
      end
    else
      case FirstPartyReleaseClient.resolve_catalog(
             release_tag,
             fn tag -> list_release_plugins(attrs, tag) end,
             fn -> list_recent_plugins(attrs, limit) end
           ) do
        {:ok, plugins, :exact} -> {:ok, plugins, release_tag}
        {:ok, plugins, :recent} -> {:ok, plugins, nil}
        {:error, _} = error -> error
      end
    end
  end

  def list_plugins_for_sync(_attrs, _opts), do: {:error, "Plugin import settings are invalid"}

  @spec import(map()) :: {:ok, map()} | {:error, term()}
  def import(attrs) when is_map(attrs) do
    with {:ok, repo} <- import_repo(attrs),
         {:ok, release_tag} <- require_value(fetch_value(attrs, [:release_tag, "release_tag"]), "Release tag is required"),
         {:ok, requested_plugin_id} <- optional_string(fetch_value(attrs, [:plugin_id, "plugin_id"])),
         {:ok, requested_version} <- optional_string(fetch_value(attrs, [:version, "version"])),
         {:ok, release} <- fetch_release(repo, release_tag),
         {:ok, index} <- fetch_release_index(repo, release, attrs),
         {:ok, entry} <- find_entry(index, requested_plugin_id, requested_version),
         {:ok, fetched} <- fetch_artifact(repo, entry),
         {:ok, bundle} <- validate_bundle(fetched.bundle, entry),
         {:ok, signature} <- decode_upload_signature(fetched.upload_signature),
         {:ok, manifest_map} <- fetch_bundle_manifest(bundle),
         {:ok, manifest_struct} <- Manifest.from_map(manifest_map),
         :ok <- verify_integration_resources(bundle, manifest_struct),
         {:ok, wasm} <- fetch_bundle_wasm(bundle),
         content_hash = Storage.sha256(wasm),
         :ok <- verify_upload_signature(signature, manifest_map, content_hash, repo),
         {:ok, display_contracts} <- bundle_display_contracts(bundle),
         :ok <- verify_entry_identity(entry, manifest_struct) do
      now = DateTime.truncate(DateTime.utc_now(), :second)

      {:ok,
       %{
         manifest: manifest_map,
         manifest_struct: manifest_struct,
         config_schema: optional_bundle_json(bundle, "config.schema.json"),
         display_contract:
           optional_bundle_json(bundle, "display_contract.json") ||
             Map.get(manifest_map, "display_contract") ||
             %{},
         display_contracts: display_contracts,
         wasm: wasm,
         content_hash: content_hash,
         signature: signature,
         source_repo_url: repo.repo_url,
         source_release_tag: release_tag,
         source_oci_ref: entry_value(entry, "oci_ref"),
         source_oci_digest: fetched.oci_digest || entry_value(entry, "oci_digest"),
         source_bundle_digest: normalize_digest(Storage.sha256(fetched.bundle)),
         source_metadata: source_metadata(repo, release, entry, fetched, now),
         imported_at: now,
         verification_status: "verified"
       }}
    end
  end

  def import(_attrs), do: {:error, :invalid_attributes}

  defp release_plugins(repo, release, attrs) do
    tag = normalize_string(Map.get(release, "tag_name"))

    cond do
      is_nil(tag) ->
        {:ok, []}

      not release_asset_present?(release, index_asset_name(attrs)) ->
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

  defp summarize_entry(repo, release, entry) do
    plugin_id = entry_value(entry, "plugin_id")
    version = entry_value(entry, "version")

    if plugin_id in [nil, ""] or version in [nil, ""] do
      nil
    else
      %{
        plugin_id: plugin_id,
        name: entry_value(entry, "name") || plugin_id,
        version: version,
        release_tag: normalize_string(Map.get(release, "tag_name")),
        release_url: normalize_string(Map.get(release, "html_url")),
        repo_url: repo.repo_url,
        oci_ref: entry_value(entry, "oci_ref"),
        oci_digest: entry_value(entry, "oci_digest"),
        bundle_digest: entry_value(entry, "bundle_digest"),
        import_ready?: import_ready_entry?(entry)
      }
    end
  end

  # Mirrors fetch_artifact/2, which tries bundle_url BEFORE oci_ref. Requiring
  # oci_ref here meant a third-party repository could never produce an
  # import-ready entry: the release-asset path documented in wasm-plugins.md
  # publishes bundle_url and upload_signature_url and has no OCI reference at
  # all, so its entries were fetchable but permanently filtered out, reported as
  # "scanned N releases, but no import-ready plugin entries were found".
  #
  # upload_signature_url is required for the direct path rather than optional,
  # because fetch_direct_artifact/2 fails without it - treating such an entry as
  # ready would move the failure from discovery to import, where it reads as a
  # broken bundle instead of an incomplete index.
  defp import_ready_entry?(entry) do
    entry_value(entry, "bundle_digest") not in [nil, ""] and
      (direct_artifact_entry?(entry) or entry_value(entry, "oci_ref") not in [nil, ""])
  end

  defp direct_artifact_entry?(entry) do
    entry_value(entry, "bundle_url") not in [nil, ""] and
      entry_value(entry, "upload_signature_url") not in [nil, ""]
  end

  defp fetch_release_index(repo, release, attrs) do
    with {:ok, asset} <- fetch_release_asset(release, index_asset_name(attrs)),
         {:ok, body} <- fetch_binary_asset(repo, asset) do
      decode_index(body)
    end
  end

  defp find_entry(index, nil, nil) do
    case index_entries(index) do
      [entry] -> {:ok, entry}
      [] -> {:error, :plugin_not_found}
      _entries -> {:error, :plugin_selection_required}
    end
  end

  defp find_entry(index, plugin_id, version) do
    entry =
      Enum.find(index_entries(index), fn entry ->
        plugin_match? = is_nil(plugin_id) or entry_value(entry, "plugin_id") == plugin_id
        version_match? = is_nil(version) or entry_value(entry, "version") == version
        plugin_match? and version_match?
      end)

    case entry do
      nil -> {:error, :plugin_not_found}
      entry -> {:ok, entry}
    end
  end

  defp fetch_artifact(repo, entry) do
    cond do
      is_binary(entry_value(entry, "bundle_url")) ->
        fetch_direct_artifact(repo, entry)

      is_binary(entry_value(entry, "oci_ref")) ->
        fetch_oci_artifact(repo, entry)

      true ->
        {:error, :artifact_reference_required}
    end
  end

  defp fetch_direct_artifact(repo, entry) do
    with {:ok, bundle_url} <- validate_provider_asset_url(repo, entry_value(entry, "bundle_url")),
         {:ok, bundle} <- fetch_url_binary(repo, bundle_url),
         {:ok, upload_signature_url} <-
           validate_provider_asset_url(repo, entry_value(entry, "upload_signature_url")),
         {:ok, upload_signature} <- fetch_url_binary(repo, upload_signature_url) do
      {:ok,
       %{
         bundle: bundle,
         upload_signature: upload_signature,
         oci_digest: entry_value(entry, "oci_digest"),
         oci_manifest: nil
       }}
    end
  end

  defp fetch_oci_artifact(repo, entry) do
    with {:ok, ref} <- parse_oci_ref(entry_value(entry, "oci_ref")),
         :ok <- validate_oci_registry(ref.registry),
         {:ok, manifest, manifest_digest} <- fetch_oci_manifest(repo, ref),
         {:ok, bundle_layer} <- find_layer(manifest, @bundle_media_type),
         {:ok, signature_layer} <- find_layer(manifest, @upload_signature_media_type),
         :ok <- verify_declared_digest(entry_value(entry, "oci_digest"), manifest_digest),
         :ok <- verify_cosign_signature(entry_value(entry, "oci_ref"), manifest_digest),
         {:ok, bundle} <- fetch_oci_blob(repo, ref, bundle_layer["digest"]),
         {:ok, upload_signature} <- fetch_oci_blob(repo, ref, signature_layer["digest"]) do
      {:ok,
       %{
         bundle: bundle,
         upload_signature: upload_signature,
         oci_digest: manifest_digest,
         oci_manifest: manifest,
         cosign_verified?: true
       }}
    end
  end

  defp validate_bundle(bundle, entry) when is_binary(bundle) do
    cond do
      byte_size(bundle) > @max_bundle_bytes ->
        {:error, :bundle_too_large}

      not digest_matches?(entry_value(entry, "bundle_digest"), bundle) ->
        {:error, :bundle_digest_mismatch}

      true ->
        extract_bundle(bundle)
    end
  end

  defp validate_bundle(_bundle, _entry), do: {:error, :invalid_bundle}

  defp extract_bundle(bundle) do
    with {:ok, listing} <- :zip.list_dir(bundle),
         :ok <- preflight_bundle_entries(listing),
         {:ok, files} <- :zip.extract(bundle, [:memory]),
         {:ok, entries} <- normalize_bundle_entries(files) do
      {:ok, entries}
    else
      {:error, reason} -> {:error, {:invalid_bundle, reason}}
      other -> {:error, {:invalid_bundle, other}}
    end
  end

  defp preflight_bundle_entries(listing) when is_list(listing) do
    file_entries = Enum.filter(listing, &match?({:zip_file, _, _, _, _, _}, &1))

    if length(file_entries) > @max_bundle_entries do
      {:error, :too_many_bundle_entries}
    else
      listing
      |> Enum.reduce_while({:ok, MapSet.new(), 0}, fn entry, {:ok, names, total_size} ->
        case bundle_listing_entry(entry) do
          :skip ->
            {:cont, {:ok, names, total_size}}

          {:ok, name, size} ->
            normalized_name = normalize_zip_name(name)
            next_total_size = total_size + size

            cond do
              is_nil(normalized_name) ->
                {:halt, {:error, :invalid_bundle_path}}

              MapSet.member?(names, normalized_name) ->
                {:halt, {:error, :duplicate_bundle_entry}}

              not allowed_bundle_entry?(normalized_name) ->
                {:halt, {:error, :unexpected_bundle_entry}}

              not allowed_bundle_entry_size?(normalized_name, size) ->
                {:halt, {:error, :bundle_entry_too_large}}

              next_total_size > @max_uncompressed_bundle_bytes ->
                {:halt, {:error, :uncompressed_bundle_too_large}}

              true ->
                {:cont, {:ok, MapSet.put(names, normalized_name), next_total_size}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, _names, _total_size} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp preflight_bundle_entries(_listing), do: {:error, :invalid_bundle_directory}

  defp bundle_listing_entry({:zip_comment, _comment}), do: :skip

  defp bundle_listing_entry({:zip_file, name, file_info, _comment, _offset, _compressed_size}) do
    case regular_zip_entry_size(file_info) do
      {:ok, size} -> {:ok, name, size}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bundle_listing_entry(_entry), do: {:error, :invalid_bundle_directory}

  defp regular_zip_entry_size(file_info)
       when is_tuple(file_info) and tuple_size(file_info) >= 3 and elem(file_info, 0) == :file_info and
              elem(file_info, 2) == :regular and is_integer(elem(file_info, 1)) and elem(file_info, 1) >= 0 do
    {:ok, elem(file_info, 1)}
  end

  defp regular_zip_entry_size(_file_info), do: {:error, :non_regular_bundle_entry}

  defp normalize_bundle_entries(files) do
    if length(files) > @max_bundle_entries do
      {:error, :too_many_bundle_entries}
    else
      Enum.reduce_while(files, {:ok, %{}}, fn {name, payload}, {:ok, acc} ->
        normalized_name = normalize_zip_name(name)

        cond do
          is_nil(normalized_name) ->
            {:halt, {:error, :invalid_bundle_path}}

          Map.has_key?(acc, normalized_name) ->
            {:halt, {:error, :duplicate_bundle_entry}}

          not allowed_bundle_entry?(normalized_name) ->
            {:halt, {:error, :unexpected_bundle_entry}}

          not allowed_bundle_entry_size?(normalized_name, payload) ->
            {:halt, {:error, :bundle_entry_too_large}}

          true ->
            {:cont, {:ok, Map.put(acc, normalized_name, payload)}}
        end
      end)
    end
  end

  defp allowed_bundle_entry?(name) do
    name in ["plugin.yaml", "plugin.wasm", "config.schema.json", "display_contract.json"] or
      (String.starts_with?(name, "docs/") and Path.extname(name) in [".md", ".txt"]) or
      ((String.starts_with?(name, "display/") or String.starts_with?(name, "schemas/")) and
         Path.extname(name) == ".json")
  end

  defp allowed_bundle_entry_size?(name, payload) when is_binary(payload),
    do: allowed_bundle_entry_size?(name, byte_size(payload))

  defp allowed_bundle_entry_size?("plugin.wasm", size) when is_integer(size), do: size <= @max_bundle_bytes

  defp allowed_bundle_entry_size?("plugin.yaml", size) when is_integer(size), do: size <= 1024 * 1024

  defp allowed_bundle_entry_size?(_name, size) when is_integer(size), do: size <= @max_resource_bytes

  defp allowed_bundle_entry_size?(_name, _payload), do: false

  defp normalize_zip_name(name) when is_list(name), do: name |> to_string() |> normalize_zip_name()

  defp normalize_zip_name(name) when is_binary(name) do
    segments = String.split(name, "/", trim: false)

    if name == "" or String.starts_with?(name, "/") or String.contains?(name, ["\\", <<0>>]) or
         Enum.any?(segments, &(&1 in ["", ".", ".."])) do
      nil
    else
      name
    end
  end

  defp normalize_zip_name(_name), do: nil

  defp fetch_bundle_manifest(bundle) do
    case Map.fetch(bundle, "plugin.yaml") do
      {:ok, yaml} -> Manifest.parse_yaml_map(yaml)
      :error -> {:error, ["bundle missing plugin.yaml"]}
    end
  end

  defp fetch_bundle_wasm(bundle) do
    case Map.fetch(bundle, "plugin.wasm") do
      {:ok, wasm} when is_binary(wasm) and byte_size(wasm) > 0 -> {:ok, wasm}
      {:ok, _wasm} -> {:error, :invalid_wasm}
      :error -> {:error, :missing_wasm}
    end
  end

  defp verify_integration_resources(bundle, manifest) do
    case get_in(manifest.integrations, ["documentation", "path"]) do
      nil -> :ok
      path when is_binary(path) -> if Map.has_key?(bundle, path), do: :ok, else: {:error, :missing_plugin_documentation}
    end
  end

  # Display contracts ship as `display/*.json` bundle entries. They are validated
  # HERE, at import, rather than at render time: a contract that reaches the
  # packages table has already been proven to be data, so the renderer never has
  # to decide whether to trust a stored document.
  #
  # Any malformed contract rejects the package/version. Import success is the
  # trust boundary the renderer relies on: silently dropping one would make the
  # signed artifact installed in storage differ from the contract operators and
  # reviewers inspected in the bundle.
  defp bundle_display_contracts(bundle) do
    contracts =
      bundle
      |> Enum.filter(fn {name, payload} ->
        is_binary(payload) and String.starts_with?(name, "display/") and Path.extname(name) == ".json"
      end)
      |> Map.new()

    case DisplayContract.validate_all(contracts) do
      {:ok, validated} -> {:ok, validated}
      {:error, errors} -> {:error, {:invalid_display_contracts, errors}}
    end
  end

  defp optional_bundle_json(bundle, name) do
    case Map.get(bundle, name) do
      payload when is_binary(payload) ->
        case Jason.decode(payload) do
          {:ok, %{} = map} -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp decode_upload_signature(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = signature} -> {:ok, signature}
      _ -> {:error, :invalid_upload_signature}
    end
  end

  defp decode_upload_signature(%{} = signature), do: {:ok, signature}
  defp decode_upload_signature(_payload), do: {:error, :invalid_upload_signature}

  # Verifies against the key of the repository this bundle came from, not a
  # global map. That is the whole point of repositories being records: a bundle
  # signed by one publisher must not verify when served from another's catalog.
  # The configured map remains the fallback for callers that pass no repository
  # keys -- the built-in source, and the importer's own unit tests.
  defp verify_upload_signature(signature, manifest, content_hash, repo) do
    keys =
      case Map.get(repo, :trusted_upload_signing_keys) do
        keys when is_map(keys) and map_size(keys) > 0 ->
          UploadSignature.normalize_trusted_keys(keys)

        _ ->
          plugin_verification_policy().trusted_upload_signing_keys
      end

    if keys == %{} do
      {:error, :trusted_upload_signers_not_configured}
    else
      UploadSignature.verify(signature, manifest, content_hash, keys)
    end
  end

  defp verify_entry_identity(entry, manifest_struct) do
    cond do
      entry_value(entry, "plugin_id") not in [nil, manifest_struct.id] ->
        {:error, :plugin_id_mismatch}

      entry_value(entry, "version") not in [nil, manifest_struct.version] ->
        {:error, :plugin_version_mismatch}

      true ->
        :ok
    end
  end

  defp source_metadata(repo, release, entry, fetched, now) do
    %{
      "source" => "first_party_github_release",
      "repo_url" => repo.repo_url,
      "release_tag" => normalize_string(Map.get(release, "tag_name")),
      "release_name" => normalize_string(Map.get(release, "name")),
      "release_url" => normalize_string(Map.get(release, "html_url")),
      "oci_ref" => entry_value(entry, "oci_ref"),
      "oci_digest" => fetched.oci_digest || entry_value(entry, "oci_digest"),
      "bundle_digest" => normalize_digest(Storage.sha256(fetched.bundle)),
      "cosign_verified" => Map.get(fetched, :cosign_verified?, false),
      "import_index_asset_name" => @default_index_asset_name,
      "verified_at" => DateTime.to_iso8601(now)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp import_repo(attrs) when is_map(attrs) do
    repo_url =
      fetch_value(attrs, [:repo_url, "repo_url"]) ||
        configured_repo_url()

    with {:ok, repo} <- parse_repo_url(repo_url) do
      {:ok,
       repo
       |> Map.put(:token, fetch_value(attrs, [:github_token, "github_token"]))
       |> Map.put(
         :trusted_upload_signing_keys,
         fetch_value(attrs, [:trusted_upload_signing_keys, "trusted_upload_signing_keys"]) || %{}
       )}
    end
  end

  defp configured_repo_url do
    config = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import, [])
    Keyword.get(config, :repo_url, FirstPartyReleaseClient.default_repo_url())
  end

  defp index_asset_name(attrs) do
    fetch_value(attrs, [:index_asset_name, "index_asset_name"]) ||
      Keyword.get(
        Application.get_env(:serviceradar_web_ng, :first_party_plugin_import, []),
        :index_asset_name,
        @default_index_asset_name
      )
  end

  # Non-integer/non-positive limits pass through unchanged so the shared client's
  # normalize_limit applies its own fallback (matching the pre-dedup behavior).
  defp clamp_recent_release_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_recent_release_scan)

  defp clamp_recent_release_limit(limit), do: limit

  defp index_entries(index) when is_map(index) do
    index
    |> Map.get("plugins", Map.get(index, :plugins, []))
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  end

  defp entry_value(entry, key) do
    atom_value =
      case key do
        "bundle_digest" -> Map.get(entry, :bundle_digest)
        "bundle_url" -> Map.get(entry, :bundle_url)
        "name" -> Map.get(entry, :name)
        "oci_digest" -> Map.get(entry, :oci_digest)
        "oci_ref" -> Map.get(entry, :oci_ref)
        "plugin_id" -> Map.get(entry, :plugin_id)
        "upload_signature_url" -> Map.get(entry, :upload_signature_url)
        "version" -> Map.get(entry, :version)
        _ -> nil
      end

    normalize_string(Map.get(entry, key) || atom_value)
  end

  defp fetch_value(attrs, keys) do
    Enum.find_value(keys, &Map.get(attrs, &1))
  end

  defp optional_string(nil), do: {:ok, nil}
  defp optional_string(""), do: {:ok, nil}

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed -> {:ok, trimmed}
    end
  end

  defp optional_string(_value), do: {:error, :invalid_selection}

  defp plugin_verification_policy do
    config = Application.get_env(:serviceradar_web_ng, :plugin_verification, [])

    %{
      trusted_upload_signing_keys:
        config
        |> Keyword.get(:trusted_upload_signing_keys, %{})
        |> UploadSignature.normalize_trusted_keys()
    }
  end
end
