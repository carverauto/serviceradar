defmodule ServiceRadarWebNG.Plugins.FirstPartyImporter do
  @moduledoc """
  Discovers and imports first-party Wasm plugin bundles from Forgejo releases.
  """

  alias ServiceRadar.Plugins.Manifest
  alias ServiceRadar.Policies.OutboundURLPolicy
  alias ServiceRadarWebNG.Plugins.CosignVerifier
  alias ServiceRadarWebNG.Plugins.Storage
  alias ServiceRadarWebNG.Plugins.UploadSignature

  @default_index_asset_name "serviceradar-wasm-plugin-index.json"
  @default_recent_release_limit 10
  @forgejo_host "code.carverauto.dev"
  @default_repo_url "https://code.carverauto.dev/carverauto/serviceradar"
  @max_asset_redirects 5
  @bundle_media_type "application/zip"
  @upload_signature_media_type "application/vnd.serviceradar.wasm-plugin.upload-signature.v1+json"
  @max_bundle_bytes 64 * 1024 * 1024

  @spec default_index_asset_name() :: String.t()
  def default_index_asset_name, do: @default_index_asset_name

  @spec default_repo_url() :: String.t()
  def default_repo_url, do: @default_repo_url

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
         {:ok, releases} <- fetch_recent_releases(repo, limit) do
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
         {:ok, wasm} <- fetch_bundle_wasm(bundle),
         content_hash = Storage.sha256(wasm),
         :ok <- verify_upload_signature(signature, manifest_map, content_hash),
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

  defp import_ready_entry?(entry) do
    entry_value(entry, "oci_ref") not in [nil, ""] and
      entry_value(entry, "bundle_digest") not in [nil, ""]
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

  defp fetch_oci_manifest(repo, ref) do
    url = "https://#{ref.registry}/v2/#{ref.repository}/manifests/#{ref.reference}"
    headers = [{"accept", "application/vnd.oci.image.manifest.v1+json"} | asset_headers("forgejo", url)]

    with {:ok, request_url} <- validate_provider_asset_url(repo, url),
         {:ok, response} <- request_oci(request_url, ref, headers: headers, decode_body: true) do
      case response do
        %Req.Response{status: 200, body: body} when is_map(body) ->
          {:ok, manifest_content(body), response_digest(response)}

        %Req.Response{status: status} ->
          {:error, {:oci_manifest_http_error, status}}
      end
    end
  end

  defp fetch_oci_blob(repo, ref, digest) do
    url = "https://#{ref.registry}/v2/#{ref.repository}/blobs/#{digest}"

    with {:ok, request_url} <- validate_provider_asset_url(repo, url) do
      fetch_oci_blob_binary(repo, ref, request_url, @max_asset_redirects)
    end
  end

  defp fetch_oci_blob_binary(_repo, _ref, _url, remaining_redirects) when remaining_redirects < 0 do
    {:error, "Plugin artifact download exceeded redirect limit"}
  end

  defp fetch_oci_blob_binary(repo, ref, url, remaining_redirects) do
    case request_oci(url, ref, headers: asset_headers("forgejo", url), decode_body: false) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, IO.iodata_to_binary(body)}

      {:ok, %Req.Response{status: status} = response} when status in [301, 302, 303, 307, 308] ->
        with {:ok, redirect_url} <- redirect_location(url, response),
             {:ok, request_url} <- validate_provider_asset_url(repo, redirect_url) do
          fetch_url_binary(repo, request_url, remaining_redirects - 1)
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:artifact_http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_url_binary(repo, url), do: fetch_url_binary(repo, url, @max_asset_redirects)

  defp fetch_url_binary(_repo, _url, remaining_redirects) when remaining_redirects < 0 do
    {:error, "Plugin artifact download exceeded redirect limit"}
  end

  defp fetch_url_binary(repo, url, remaining_redirects) do
    case request(url, headers: asset_headers("forgejo", url), decode_body: false) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, IO.iodata_to_binary(body)}

      {:ok, %Req.Response{status: status} = response} when status in [301, 302, 303, 307, 308] ->
        with {:ok, redirect_url} <- redirect_location(url, response),
             {:ok, request_url} <- validate_provider_asset_url(repo, redirect_url) do
          fetch_url_binary(repo, request_url, remaining_redirects - 1)
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:artifact_http_error, status}}

      {:error, reason} ->
        {:error, reason}
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
    path = Path.join(System.tmp_dir!(), "sr-plugin-bundle-#{System.unique_integer([:positive])}.zip")

    try do
      File.write!(path, bundle)

      with {:ok, files} <- :zip.extract(String.to_charlist(path), [:memory]),
           {:ok, entries} <- normalize_bundle_entries(files) do
        {:ok, entries}
      else
        {:error, reason} -> {:error, {:invalid_bundle, reason}}
        other -> {:error, {:invalid_bundle, other}}
      end
    after
      File.rm(path)
    end
  end

  defp normalize_bundle_entries(files) do
    Enum.reduce_while(files, {:ok, %{}}, fn {name, payload}, {:ok, acc} ->
      normalized_name = normalize_zip_name(name)

      cond do
        is_nil(normalized_name) ->
          {:halt, {:error, :invalid_bundle_path}}

        normalized_name in ["plugin.yaml", "plugin.wasm", "config.schema.json", "display_contract.json"] ->
          {:cont, {:ok, Map.put(acc, normalized_name, payload)}}

        true ->
          {:halt, {:error, :unexpected_bundle_entry}}
      end
    end)
  end

  defp normalize_zip_name(name) when is_list(name), do: name |> to_string() |> normalize_zip_name()

  defp normalize_zip_name(name) when is_binary(name) do
    name = String.trim_leading(name, "/")

    if String.contains?(name, ["..", "\\"]) or name == "" do
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

  defp verify_upload_signature(signature, manifest, content_hash) do
    policy = plugin_verification_policy()

    if policy.trusted_upload_signing_keys == %{} do
      {:error, :trusted_upload_signers_not_configured}
    else
      UploadSignature.verify(signature, manifest, content_hash, policy.trusted_upload_signing_keys)
    end
  end

  defp verify_cosign_signature(nil, _digest), do: {:error, :oci_ref_required}
  defp verify_cosign_signature(_ref, nil), do: {:error, :oci_digest_required}

  defp verify_cosign_signature(ref, digest) do
    verifier = Application.get_env(:serviceradar_web_ng, :first_party_plugin_cosign_verifier, CosignVerifier)
    verifier.verify(%{ref: ref, digest: digest})
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
      "source" => "first_party_forgejo_release",
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

    parse_repo_url(repo_url)
  end

  defp parse_repo_url(url) when is_binary(url) do
    with %URI{scheme: "https", host: @forgejo_host} = uri <- URI.parse(String.trim(url)),
         {:ok, owner, repo} <- repo_owner_and_name(uri.path) do
      {:ok,
       %{
         provider: "forgejo",
         repo_url: "https://#{host_port(uri)}/#{owner}/#{repo}",
         api_base_url: "https://#{host_port(uri)}/api/v1",
         owner: owner,
         repo: repo
       }}
    else
      _ -> {:error, "Forgejo repository URL must look like https://code.carverauto.dev/<owner>/<repo>"}
    end
  end

  defp parse_repo_url(_url), do: {:error, "Forgejo repository URL is required"}

  defp repo_owner_and_name(path) when is_binary(path) do
    case path |> String.split("/", trim: true) |> Enum.take(2) do
      [owner, repo] ->
        repo = String.trim_trailing(repo, ".git")

        if owner != "" and repo != "" do
          {:ok, owner, repo}
        else
          {:error, :invalid_repo_path}
        end

      _ ->
        {:error, :invalid_repo_path}
    end
  end

  defp configured_repo_url do
    config = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import, [])
    Keyword.get(config, :repo_url, @default_repo_url)
  end

  defp index_asset_name(attrs) do
    fetch_value(attrs, [:index_asset_name, "index_asset_name"]) ||
      Keyword.get(
        Application.get_env(:serviceradar_web_ng, :first_party_plugin_import, []),
        :index_asset_name,
        @default_index_asset_name
      )
  end

  defp fetch_release(repo, tag) do
    url = "#{repo.api_base_url}/repos/#{repo.owner}/#{repo.repo}/releases/tags/#{URI.encode(tag)}"

    with {:ok, request_url} <- validate_provider_api_url(repo, url),
         {:ok, response} <- request(request_url, headers: api_headers("forgejo"), decode_body: true) do
      case response do
        %Req.Response{status: 200, body: body} when is_map(body) -> {:ok, body}
        %Req.Response{status: 404} -> {:error, "Release tag #{tag} was not found"}
        %Req.Response{status: status} -> {:error, "Release import failed with HTTP #{status}"}
      end
    end
  end

  defp fetch_recent_releases(repo, limit) do
    url = "#{repo.api_base_url}/repos/#{repo.owner}/#{repo.repo}/releases?per_page=#{normalize_limit(limit)}"

    with {:ok, request_url} <- validate_provider_api_url(repo, url),
         {:ok, response} <- request(request_url, headers: api_headers("forgejo"), decode_body: true) do
      case response do
        %Req.Response{status: 200, body: body} when is_list(body) -> {:ok, body}
        %Req.Response{status: 200} -> {:error, "Plugin release browser returned an unexpected payload"}
        %Req.Response{status: status} -> {:error, "Recent plugin releases could not be loaded (HTTP #{status})"}
      end
    end
  end

  defp fetch_release_asset(release, asset_name) do
    assets = List.wrap(Map.get(release, "assets"))

    case Enum.find(assets, &(normalize_string(Map.get(&1, "name")) == asset_name)) do
      nil -> {:error, "Release asset #{asset_name} was not found"}
      asset -> {:ok, asset}
    end
  end

  defp fetch_binary_asset(repo, asset) do
    with {:ok, url} <- require_value(Map.get(asset, "browser_download_url"), "Release asset URL is missing"),
         {:ok, request_url} <- validate_provider_asset_url(repo, url) do
      fetch_url_binary(repo, request_url)
    end
  end

  defp release_asset_present?(release, asset_name) do
    release
    |> Map.get("assets")
    |> List.wrap()
    |> Enum.any?(&(normalize_string(Map.get(&1, "name")) == asset_name))
  end

  defp decode_index(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = index} -> {:ok, index}
      {:ok, _} -> {:error, "Plugin import index must contain a JSON object"}
      {:error, _} -> {:error, "Plugin import index asset is not valid JSON"}
    end
  end

  defp index_entries(index) when is_map(index) do
    index
    |> Map.get("plugins", Map.get(index, :plugins, []))
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  end

  defp parse_oci_ref(ref) when is_binary(ref) do
    ref = String.trim(ref)

    cond do
      ref == "" ->
        {:error, :invalid_oci_ref}

      String.contains?(ref, "@") ->
        [name, digest] = String.split(ref, "@", parts: 2)
        parse_oci_name(name, digest)

      true ->
        case Regex.run(~r/^(.+):([^\/:]+)$/, ref) do
          [_full, name, tag] -> parse_oci_name(name, tag)
          _ -> {:error, :invalid_oci_ref}
        end
    end
  end

  defp parse_oci_ref(_ref), do: {:error, :invalid_oci_ref}

  defp parse_oci_name(name, reference) do
    case String.split(name, "/", parts: 2) do
      [registry, repository] when registry != "" and repository != "" and reference != "" ->
        {:ok, %{registry: registry, repository: repository, reference: reference}}

      _ ->
        {:error, :invalid_oci_ref}
    end
  end

  defp validate_oci_registry("registry.carverauto.dev"), do: :ok
  defp validate_oci_registry(_registry), do: {:error, :untrusted_oci_registry}

  defp manifest_content(%{"content" => %{} = content}), do: content
  defp manifest_content(%{} = manifest), do: manifest

  defp response_digest(response) do
    response
    |> Req.Response.get_header("docker-content-digest")
    |> List.first()
    |> normalize_string()
  end

  defp find_layer(manifest, media_type) do
    layer =
      manifest
      |> Map.get("layers", [])
      |> Enum.find(&(Map.get(&1, "mediaType") == media_type))

    case layer do
      %{"digest" => digest} when is_binary(digest) -> {:ok, layer}
      _ -> {:error, :oci_layer_missing}
    end
  end

  defp verify_declared_digest(nil, _actual), do: :ok
  defp verify_declared_digest("", _actual), do: :ok
  defp verify_declared_digest(_declared, nil), do: :ok

  defp verify_declared_digest(declared, actual) do
    if normalize_digest(declared) == normalize_digest(actual) do
      :ok
    else
      {:error, :oci_digest_mismatch}
    end
  end

  defp digest_matches?(nil, _payload), do: true
  defp digest_matches?("", _payload), do: true

  defp digest_matches?(expected, payload) when is_binary(expected) and is_binary(payload) do
    normalize_digest(expected) == normalize_digest(Storage.sha256(payload))
  end

  defp normalize_digest(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("sha256:", "")
  end

  defp normalize_digest(_value), do: nil

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

  defp require_value(value, message) do
    case normalize_string(value) do
      nil -> {:error, message}
      present -> {:ok, present}
    end
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 20)
  defp normalize_limit(_limit), do: @default_recent_release_limit

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(value), do: value |> to_string() |> normalize_string()

  defp host_port(%URI{scheme: "https", host: host, port: 443}), do: host
  defp host_port(%URI{host: host, port: nil}), do: host
  defp host_port(%URI{host: host, port: port}), do: "#{host}:#{port}"

  defp api_headers("forgejo") do
    [{"user-agent", "serviceradar"}, {"accept", "application/json"} | auth_headers("forgejo")]
  end

  defp asset_headers(_provider, url) do
    headers = [{"user-agent", "serviceradar"}]

    if auth_host?(url) do
      headers ++ auth_headers("forgejo")
    else
      headers
    end
  end

  defp auth_headers("forgejo") do
    case Application.get_env(:serviceradar_web_ng, :first_party_plugin_import_forgejo_token) ||
           System.get_env("FORGEJO_TOKEN") do
      nil -> []
      token -> [{"authorization", "token #{token}"}]
    end
  end

  defp auth_host?(url) do
    case URI.parse(url) do
      %URI{host: @forgejo_host} -> true
      _ -> false
    end
  end

  defp http_client do
    Application.get_env(:serviceradar_web_ng, :first_party_plugin_import_http_client, Req)
  end

  defp request(url, opts) do
    request_opts =
      opts
      |> Keyword.put(:redirect, false)
      |> Keyword.merge(req_opts())

    http_client().get(url, request_opts)
  end

  defp request_oci(url, ref, opts) do
    case request(url, opts) do
      {:ok, %Req.Response{status: 401} = response} ->
        with {:ok, token} <- fetch_oci_bearer_token(ref, response) do
          headers =
            opts
            |> Keyword.get(:headers, [])
            |> put_header("authorization", "Bearer #{token}")

          request(url, Keyword.put(opts, :headers, headers))
        end

      other ->
        other
    end
  end

  defp fetch_oci_bearer_token(ref, response) do
    with {:ok, challenge} <- oci_bearer_challenge(response),
         {:ok, token_url} <- oci_token_url(challenge, ref),
         headers = [{"accept", "application/json"} | registry_basic_auth_headers(ref.registry)],
         {:ok, %Req.Response{status: 200, body: body}} <- request(token_url, headers: headers, decode_body: true),
         token when is_binary(token) and token != "" <- Map.get(body, "token") || Map.get(body, "access_token") do
      {:ok, token}
    else
      {:ok, %Req.Response{status: status}} -> {:error, {:oci_token_http_error, status}}
      nil -> {:error, :oci_token_missing}
      "" -> {:error, :oci_token_missing}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :oci_token_missing}
    end
  end

  defp oci_bearer_challenge(response) do
    response
    |> Req.Response.get_header("www-authenticate")
    |> List.wrap()
    |> Enum.find_value(fn header ->
      if String.starts_with?(String.downcase(header), "bearer ") do
        params =
          ~r/([A-Za-z_]+)="([^"]*)"/
          |> Regex.scan(header)
          |> Map.new(fn [_match, key, value] -> {String.downcase(key), value} end)

        {:ok, params}
      end
    end)
    |> case do
      {:ok, %{"realm" => _realm} = params} -> {:ok, params}
      _ -> {:error, :oci_auth_challenge_missing}
    end
  end

  defp oci_token_url(%{"realm" => realm} = challenge, ref) do
    params =
      challenge
      |> Map.take(["service", "scope"])
      |> Map.update("scope", "repository:#{ref.repository}:pull", fn
        "" -> "repository:#{ref.repository}:pull"
        scope -> scope
      end)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

    case validate_url(realm) do
      {:ok, %URI{host: "registry.carverauto.dev"} = uri} ->
        query =
          uri.query
          |> decode_query()
          |> Kernel.++(params)
          |> URI.encode_query()

        {:ok, URI.to_string(%{uri | query: query})}

      {:ok, _uri} ->
        {:error, :untrusted_oci_token_realm}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_query(nil), do: []
  defp decode_query(query), do: query |> URI.decode_query() |> Enum.to_list()

  defp registry_basic_auth_headers(registry) do
    case registry_basic_auth(registry) do
      {:ok, auth} -> [{"authorization", "Basic #{auth}"}]
      :error -> []
    end
  end

  defp registry_basic_auth(registry) do
    config = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import, [])

    config
    |> registry_docker_config_payload()
    |> decode_docker_auth(registry)
  end

  defp registry_docker_config_payload(config) do
    cond do
      payload = Keyword.get(config, :registry_docker_config_json) ->
        payload

      path = Keyword.get(config, :registry_docker_config_file) ->
        case File.read(path) do
          {:ok, payload} -> payload
          {:error, _reason} -> nil
        end

      true ->
        nil
    end
  end

  defp decode_docker_auth(nil, _registry), do: :error

  defp decode_docker_auth(payload, registry) when is_binary(payload) do
    with {:ok, %{"auths" => auths}} when is_map(auths) <- Jason.decode(payload),
         {:ok, auth_config} <- find_registry_auth(auths, registry) do
      cond do
        auth = normalize_string(Map.get(auth_config, "auth")) ->
          {:ok, auth}

        username = normalize_string(Map.get(auth_config, "username")) ->
          password = normalize_string(Map.get(auth_config, "password")) || ""
          {:ok, Base.encode64("#{username}:#{password}")}

        true ->
          :error
      end
    else
      _ -> :error
    end
  end

  defp decode_docker_auth(_payload, _registry), do: :error

  defp find_registry_auth(auths, registry) do
    auths
    |> Enum.find_value(fn {key, value} ->
      if docker_auth_key_matches?(key, registry), do: {:ok, value}
    end)
    |> case do
      {:ok, %{} = auth_config} -> {:ok, auth_config}
      _ -> :error
    end
  end

  defp docker_auth_key_matches?(key, registry) do
    case URI.parse(key) do
      %URI{host: host} when is_binary(host) -> host == registry
      %URI{path: ^registry} -> true
      _ -> false
    end
  end

  defp put_header(headers, key, value) do
    normalized_key = String.downcase(key)

    headers
    |> Enum.reject(fn {existing_key, _value} -> String.downcase(to_string(existing_key)) == normalized_key end)
    |> then(&[{key, value} | &1])
  end

  defp validate_provider_api_url(_repo, url) do
    with {:ok, uri} <- validate_url(url),
         true <- uri.host == @forgejo_host do
      {:ok, URI.to_string(uri)}
    else
      false -> {:error, "plugin import provider URL is not trusted"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_provider_asset_url(_repo, url) do
    with {:ok, uri} <- validate_url(url),
         true <- uri.host in [@forgejo_host, "registry.carverauto.dev"] do
      {:ok, URI.to_string(uri)}
    else
      false -> {:error, "plugin import asset URL is not trusted"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_url(url) do
    case OutboundURLPolicy.validate_https_public_url(url) do
      {:ok, %URI{scheme: "https"} = uri} -> {:ok, uri}
      {:error, _reason} = error -> error
      _ -> {:error, :disallowed_url}
    end
  end

  defp req_opts do
    [connect_options: [timeout: 5_000], receive_timeout: 10_000, redirect: false]
  end

  defp redirect_location(request_url, response) do
    case Req.Response.get_header(response, "location") do
      [location | _] ->
        resolved =
          request_url
          |> URI.parse()
          |> URI.merge(location)
          |> URI.to_string()

        {:ok, resolved}

      _ ->
        {:error, :missing_redirect_location}
    end
  end

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
