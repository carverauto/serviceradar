defmodule ServiceRadar.Catalog.ReleaseCatalogClient do
  @moduledoc """
  Fetches and verifies signed Solution Pack release catalogs (`mode: :release_catalog`)
  through `ServiceRadar.HTTP.EgressClient` (`3.2`, Decision 4).

  Supports:
  1. GitHub and Gitea/Forgejo release repositories (e.g.
     `https://github.com/carverauto/serviceradar`), resolving the release index
     asset (`serviceradar-pack-index.json`), `.srpack` archive, and `.srpack.sig`
     signature over HTTPS (using API asset endpoints with `Accept: application/octet-stream`
     for private repositories while relying on `EgressClient` cross-origin header
     stripping so `Authorization` never reaches pre-signed redirect hosts).
  2. Direct HTTPS catalog portal index endpoints (e.g.
     `https://developer.serviceradar.cloud` or
     `https://developer.serviceradar.cloud/packs/index.json`).

  Every `.srpack` archive MUST match its declared SHA-256 digest and verify via
  `ServiceRadar.Catalog.UploadSignature.verify/4` against *that repository's*
  trusted ed25519 key BEFORE archive extraction.
  """

  alias ServiceRadar.Catalog.CatalogNotifier
  alias ServiceRadar.Catalog.CatalogRepository
  alias ServiceRadar.Catalog.PackArchive
  alias ServiceRadar.Catalog.PackManifest
  alias ServiceRadar.Catalog.RepositoryCredentials
  alias ServiceRadar.Catalog.RepoUrl
  alias ServiceRadar.Catalog.UploadSignature
  alias ServiceRadar.HTTP.EgressClient

  @max_index_bytes 5 * 1024 * 1024
  @max_sig_bytes 65_536

  @doc """
  Fetches and parses the remote `serviceradar-pack-index.json` catalog for `repo`.

  Returns `{:ok, %{release_tag: tag | nil, index_url: url, entries: [map()]}}`.
  """
  @spec fetch_index(CatalogRepository.t() | map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def fetch_index(repo, opts \\ []) when is_map(repo) and is_list(opts) do
    with {:ok, parsed} <- RepoUrl.parse(repo.repo_url, repo.provider_type, :release_catalog),
         {:ok, token} <- RepositoryCredentials.fetch_token(repo, opts) do
      case parsed.kind do
        :portal_index ->
          fetch_portal_index(parsed, token, opts)

        :git_repo ->
          fetch_git_release_index(repo, parsed, token, opts)
      end
    end
  end

  @doc """
  Downloads, verifies (SHA-256 + per-repository ed25519 signature BEFORE archive
  extraction), and extracts a Solution Pack from `repo`.
  """
  @spec fetch_and_verify_pack(CatalogRepository.t() | map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def fetch_and_verify_pack(repo, pack_id_or_slug, opts \\ [])
      when is_map(repo) and is_binary(pack_id_or_slug) and is_list(opts) do
    requested_version = Keyword.get(opts, :version)
    trusted_keys = CatalogRepository.trusted_signing_keys(repo)

    if trusted_keys == %{} do
      {:error, :trusted_signing_key_not_configured}
    else
      with {:ok, parsed} <- RepoUrl.parse(repo.repo_url, repo.provider_type, :release_catalog),
           {:ok, token} <- RepositoryCredentials.fetch_token(repo, opts),
           {:ok, index_data} <- resolve_index_data(repo, parsed, token, opts),
           {:ok, entry} <-
             select_pack_entry(index_data.entries, pack_id_or_slug, requested_version),
           {:ok, bundle_bytes, sig_map} <-
             download_bundle_and_sig(repo, parsed, index_data, entry, token, opts),
           actual_hash = PackManifest.sha256_hex(bundle_bytes),
           :ok <- verify_declared_entry_digest(entry, actual_hash),
           :ok <- verify_pre_extraction_signature(sig_map, entry, actual_hash, trusted_keys),
           {:ok, validated} <- PackArchive.extract(bundle_bytes, opts),
           :ok <- UploadSignature.verify(sig_map, validated.manifest, actual_hash, trusted_keys),
           :ok <- verify_manifest_matches_entry(validated.manifest, entry) do
        maybe_audit_import(repo, validated.manifest, index_data.release_tag, actual_hash, opts)

        {:ok,
         %{
           pack: validated,
           bundle_bytes: bundle_bytes,
           content_hash: actual_hash,
           signature: sig_map,
           release_tag: index_data.release_tag,
           catalog_repository_id: Map.get(repo, :id)
         }}
      end
    end
  end

  ## Portal Index Fetch

  defp fetch_portal_index(parsed, token, opts) do
    headers = build_portal_headers(token)

    with {:ok, body} <- http_fetch_binary(parsed.index_url, headers, @max_index_bytes, opts),
         {:ok, entries} <- decode_pack_index(body, parsed.index_url) do
      {:ok,
       %{
         release_tag: nil,
         index_url: parsed.index_url,
         assets_by_name: %{},
         entries: entries
       }}
    end
  end

  ## GitHub / Gitea Release Index Fetch

  defp fetch_git_release_index(repo, parsed, token, opts) do
    release_tag = Keyword.get(opts, :release_tag)
    index_asset_name = Map.get(repo, :index_asset_name) || "serviceradar-pack-index.json"

    with {:ok, release} <- fetch_release_metadata(parsed, release_tag, token, opts),
         {:ok, assets_by_name} <- index_release_assets(release),
         {:ok, index_asset} <- fetch_named_asset(assets_by_name, index_asset_name),
         {:ok, index_bytes} <-
           download_release_asset(parsed, index_asset, token, @max_index_bytes, opts),
         {:ok, entries} <-
           decode_pack_index(index_bytes, index_asset["browser_download_url"] || parsed.repo_url) do
      {:ok,
       %{
         release_tag: Map.get(release, "tag_name"),
         index_url: index_asset["browser_download_url"] || index_asset["url"],
         assets_by_name: assets_by_name,
         entries: entries
       }}
    end
  end

  defp resolve_index_data(repo, _parsed, _token, opts) do
    case Keyword.get(opts, :index_data) do
      %{"entries" => entries} = preloaded when is_list(entries) ->
        {:ok,
         %{
           release_tag: Map.get(preloaded, "release_tag"),
           index_url: Map.get(preloaded, "index_url"),
           assets_by_name: Map.get(preloaded, "assets_by_name", %{}),
           entries: entries
         }}

      %{entries: entries} = preloaded when is_list(entries) ->
        {:ok, Map.put_new(preloaded, :assets_by_name, %{})}

      _ ->
        fetch_index(repo, opts)
    end
  end

  defp fetch_release_metadata(parsed, release_tag, token, opts) do
    url = release_api_url(parsed, release_tag)
    headers = build_api_json_headers(parsed.provider, token)

    with {:ok, body} <- http_fetch_binary(url, headers, @max_index_bytes, opts),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body) do
      {:ok, decoded}
    else
      {:ok, _other} -> {:error, :invalid_release_payload}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_release_json}
      {:error, reason} -> {:error, reason}
    end
  end

  defp release_api_url(%{provider: :github, api_base_url: base, owner: owner, repo: repo}, nil) do
    "#{base}/repos/#{owner}/#{repo}/releases/latest"
  end

  defp release_api_url(%{provider: :github, api_base_url: base, owner: owner, repo: repo}, tag) do
    "#{base}/repos/#{owner}/#{repo}/releases/tags/#{URI.encode_www_form(tag)}"
  end

  defp release_api_url(%{provider: :gitea, api_base_url: base, owner: owner, repo: repo}, nil) do
    "#{base}/repos/#{owner}/#{repo}/releases/latest"
  end

  defp release_api_url(%{provider: :gitea, api_base_url: base, owner: owner, repo: repo}, tag) do
    "#{base}/repos/#{owner}/#{repo}/releases/tags/#{URI.encode_www_form(tag)}"
  end

  defp index_release_assets(%{"assets" => assets}) when is_list(assets) do
    map =
      Enum.reduce(assets, %{}, fn asset, acc ->
        case Map.get(asset, "name") do
          name when is_binary(name) and name != "" -> Map.put(acc, name, asset)
          _ -> acc
        end
      end)

    {:ok, map}
  end

  defp index_release_assets(_other), do: {:error, :release_assets_missing}

  defp fetch_named_asset(assets_by_name, name) do
    case Map.fetch(assets_by_name, name) do
      {:ok, asset} -> {:ok, asset}
      :error -> {:error, {:release_asset_not_found, name}}
    end
  end

  defp download_release_asset(parsed, asset, token, max_bytes, opts) do
    cond do
      is_binary(token) and token != "" and parsed.provider == :github and is_binary(asset["url"]) ->
        headers = [
          {"authorization", "Bearer #{token}"},
          {"accept", "application/octet-stream"},
          {"user-agent", "ServiceRadar-Catalog/1.0"}
        ]

        http_fetch_binary(asset["url"], headers, max_bytes, opts)

      is_binary(token) and token != "" and parsed.provider == :gitea ->
        target = asset["browser_download_url"] || asset["url"]

        headers = [
          {"authorization", "token #{token}"},
          {"accept", "application/octet-stream"},
          {"user-agent", "ServiceRadar-Catalog/1.0"}
        ]

        http_fetch_binary(target, headers, max_bytes, opts)

      true ->
        target = asset["browser_download_url"] || asset["url"]

        headers = [
          {"accept", "application/octet-stream"},
          {"user-agent", "ServiceRadar-Catalog/1.0"}
        ]

        http_fetch_binary(target, headers, max_bytes, opts)
    end
  end

  defp download_bundle_and_sig(_repo, parsed, index_data, entry, token, opts) do
    max_bundle =
      Keyword.get(opts, :max_compressed_bytes, PackArchive.max_compressed_bytes_with_dashboards())

    with {:ok, bundle_bytes} <-
           fetch_entry_artifact(parsed, index_data, entry, :bundle, token, max_bundle, opts),
         {:ok, sig_bytes} <-
           fetch_entry_artifact(
             parsed,
             index_data,
             entry,
             :signature,
             token,
             @max_sig_bytes,
             opts
           ),
         {:ok, sig_map} <- decode_signature_json(sig_bytes) do
      {:ok, bundle_bytes, sig_map}
    end
  end

  defp fetch_entry_artifact(parsed, index_data, entry, role, token, max_bytes, opts) do
    file_name =
      case role do
        :bundle -> entry["bundle_file"] || basename_from_url(entry_bundle_url(entry))
        :signature -> entry["signature_file"] || basename_from_url(entry_sig_url(entry))
      end

    raw_url =
      case role do
        :bundle -> entry_bundle_url(entry)
        :signature -> entry_sig_url(entry)
      end

    case Map.get(index_data.assets_by_name || %{}, file_name) do
      asset when is_map(asset) ->
        download_release_asset(parsed, asset, token, max_bytes, opts)

      nil ->
        with {:ok, resolved_url} <- resolve_artifact_url(raw_url, index_data.index_url) do
          headers = build_direct_download_headers(parsed, resolved_url, token)
          http_fetch_binary(resolved_url, headers, max_bytes, opts)
        end
    end
  end

  defp resolve_artifact_url(url, base_url) when is_binary(url) and url != "" do
    merged =
      if is_binary(base_url) and base_url != "" do
        URI.merge(base_url, url)
      else
        URI.parse(url)
      end

    case merged do
      %URI{scheme: "https", host: host, userinfo: nil} = u when is_binary(host) and host != "" ->
        {:ok, URI.to_string(u)}

      _ ->
        {:error, {:invalid_artifact_url, url}}
    end
  end

  defp resolve_artifact_url(_other, _base_url), do: {:error, :artifact_url_missing}

  defp build_direct_download_headers(parsed, target_url, token) do
    base = [{"accept", "application/octet-stream"}, {"user-agent", "ServiceRadar-Catalog/1.0"}]

    if is_binary(token) and token != "" and same_host?(parsed.host, target_url) do
      auth =
        if parsed.provider == :gitea,
          do: {"authorization", "token #{token}"},
          else: {"authorization", "Bearer #{token}"}

      [auth | base]
    else
      base
    end
  end

  defp same_host?(expected_host, target_url) do
    case URI.parse(target_url) do
      %URI{host: h} when is_binary(h) -> String.downcase(h) == String.downcase(expected_host)
      _ -> false
    end
  end

  defp verify_declared_entry_digest(entry, actual_hash) do
    case entry_digest(entry) do
      nil ->
        :ok

      "" ->
        :ok

      declared ->
        if String.downcase(String.trim(declared)) == actual_hash do
          :ok
        else
          {:error, :bundle_digest_mismatch}
        end
    end
  end

  defp verify_pre_extraction_signature(sig_map, entry, actual_hash, trusted_keys) do
    case Map.get(entry, "manifest") do
      manifest when is_map(manifest) and map_size(manifest) > 0 ->
        UploadSignature.verify(sig_map, manifest, actual_hash, trusted_keys)

      _ ->
        sig_key_id = to_string(Map.get(sig_map, "key_id") || Map.get(sig_map, :key_id) || "")
        sig_hash = Map.get(sig_map, "content_hash") || Map.get(sig_map, :content_hash)
        normalized_keys = UploadSignature.normalize_trusted_keys(trusted_keys)

        cond do
          sig_key_id == "" ->
            {:error, :signature_required}

          not Map.has_key?(normalized_keys, sig_key_id) ->
            {:error, :untrusted_signer}

          is_binary(sig_hash) and String.trim(sig_hash) != "" and
              String.downcase(String.trim(sig_hash)) != actual_hash ->
            {:error, :content_hash_mismatch}

          true ->
            :ok
        end
    end
  end

  defp verify_manifest_matches_entry(manifest, entry) do
    entry_id = Map.get(entry, "id") || Map.get(entry, "pack_id")
    entry_ver = Map.get(entry, "version")

    cond do
      is_binary(entry_id) and entry_id != "" and entry_id != manifest["id"] ->
        {:error, :pack_id_mismatch}

      is_binary(entry_ver) and entry_ver != "" and entry_ver != manifest["version"] ->
        {:error, :pack_version_mismatch}

      true ->
        :ok
    end
  end

  defp decode_pack_index(bytes, base_url) when is_binary(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{"packs" => packs}} when is_list(packs) ->
        {:ok, Enum.map(packs, &normalize_index_entry(&1, base_url))}

      {:ok, %{"entries" => packs}} when is_list(packs) ->
        {:ok, Enum.map(packs, &normalize_index_entry(&1, base_url))}

      {:ok, packs} when is_list(packs) ->
        {:ok, Enum.map(packs, &normalize_index_entry(&1, base_url))}

      {:ok, _other} ->
        {:error, :invalid_pack_index_shape}

      {:error, _} ->
        {:error, :invalid_pack_index_json}
    end
  end

  defp normalize_index_entry(raw, base_url) when is_map(raw) do
    entry = Map.new(raw, fn {k, v} -> {to_string(k), v} end)

    bundle_url =
      case entry_bundle_url(entry) do
        u when is_binary(u) and u != "" ->
          case resolve_artifact_url(u, base_url) do
            {:ok, abs} -> abs
            _ -> u
          end

        _ ->
          nil
      end

    sig_url =
      case entry_sig_url(entry) do
        u when is_binary(u) and u != "" ->
          case resolve_artifact_url(u, base_url) do
            {:ok, abs} -> abs
            _ -> u
          end

        _ ->
          nil
      end

    entry
    |> maybe_put_non_nil("bundle_url", bundle_url)
    |> maybe_put_non_nil("upload_signature_url", sig_url)
  end

  defp maybe_put_non_nil(m, _k, nil), do: m
  defp maybe_put_non_nil(m, k, v), do: Map.put(m, k, v)

  defp select_pack_entry(entries, id_or_slug, requested_version) do
    candidates =
      Enum.filter(entries, fn e ->
        matches_id? =
          e["id"] == id_or_slug or e["pack_id"] == id_or_slug or e["slug"] == id_or_slug

        matches_ver? = is_nil(requested_version) or e["version"] == requested_version
        matches_id? and matches_ver?
      end)

    case candidates do
      [first | _] -> {:ok, first}
      [] -> {:error, :pack_not_found}
    end
  end

  defp entry_bundle_url(entry) do
    entry["bundle_url"] || entry["download_url"] || entry["srpack_url"]
  end

  defp entry_sig_url(entry) do
    entry["upload_signature_url"] || entry["signature_url"] || entry["sig_url"]
  end

  defp entry_digest(entry) do
    entry["bundle_digest"] || entry["sha256"] || entry["content_hash"]
  end

  defp basename_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{path: p} when is_binary(p) -> Path.basename(p)
      _ -> nil
    end
  end

  defp basename_from_url(_), do: nil

  defp decode_signature_json(bytes) when is_binary(bytes) do
    case Jason.decode(bytes) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_upload_signature}
    end
  end

  defp build_portal_headers(nil),
    do: [{"accept", "application/json"}, {"user-agent", "ServiceRadar-Catalog/1.0"}]

  defp build_portal_headers(""),
    do: [{"accept", "application/json"}, {"user-agent", "ServiceRadar-Catalog/1.0"}]

  defp build_portal_headers(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/json"},
      {"user-agent", "ServiceRadar-Catalog/1.0"}
    ]
  end

  defp build_api_json_headers(_provider, nil),
    do: [{"accept", "application/json"}, {"user-agent", "ServiceRadar-Catalog/1.0"}]

  defp build_api_json_headers(_provider, ""),
    do: [{"accept", "application/json"}, {"user-agent", "ServiceRadar-Catalog/1.0"}]

  defp build_api_json_headers(:gitea, token) do
    [
      {"authorization", "token #{token}"},
      {"accept", "application/json"},
      {"user-agent", "ServiceRadar-Catalog/1.0"}
    ]
  end

  defp build_api_json_headers(_github_or_other, token) do
    [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/vnd.github+json"},
      {"user-agent", "ServiceRadar-Catalog/1.0"}
    ]
  end

  defp http_fetch_binary(url, headers, max_bytes, opts) do
    http_opts =
      opts
      |> Keyword.take([
        :proxy,
        :profile,
        :cacerts,
        :cacertfile,
        :receive_timeout,
        :connect_timeout,
        :validate_redirect,
        :max_redirects
      ])
      |> Keyword.put(:headers, headers)
      |> Keyword.put(:max_bytes, max_bytes)

    fetcher =
      case Keyword.get(opts, :http_fetch_body) do
        fun when is_function(fun, 2) -> fun
        _ -> &EgressClient.fetch_body/2
      end

    case fetcher.(url, http_opts) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, _} = err ->
        err
    end
  end

  defp maybe_audit_import(repo, manifest, release_tag, content_hash, opts) do
    if Keyword.get(opts, :emit_audit, false) == true do
      CatalogNotifier.write_operation_audit(:release_catalog_import,
        resource_type: "solution_pack",
        resource_id: manifest["id"],
        resource_name: manifest["name"],
        actor: Keyword.get(opts, :actor),
        details: %{
          "repo_url" => Map.get(repo, :repo_url),
          "release_tag" => release_tag,
          "pack_id" => manifest["id"],
          "pack_version" => manifest["version"],
          "content_hash" => content_hash
        }
      )
    end
  end
end
