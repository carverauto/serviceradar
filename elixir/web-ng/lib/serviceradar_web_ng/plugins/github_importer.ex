defmodule ServiceRadarWebNG.Plugins.GitHubImporter do
  @moduledoc """
  Fetches plugin and dashboard packages from GitHub repositories.
  """

  alias ServiceRadar.Dashboards.Manifest, as: DashboardManifest
  alias ServiceRadar.Plugins.Manifest, as: PluginManifest
  alias ServiceRadarWebNG.Plugins.Storage

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @default_manifest_path "plugin.yaml"
  @default_wasm_path "plugin.wasm"
  @default_dashboard_manifest_path "dashboard.json"
  @max_ref_length 200
  @max_path_length 240

  @spec fetch(map()) :: {:ok, map()} | {:error, term()}
  def fetch(attrs) when is_map(attrs) do
    repo_url = fetch_value(attrs, [:source_repo_url, "source_repo_url"])
    commit = fetch_value(attrs, [:source_commit, "source_commit"])

    manifest_path =
      fetch_value(attrs, [:manifest_path, "manifest_path"]) || @default_manifest_path

    wasm_path = fetch_value(attrs, [:wasm_path, "wasm_path"]) || @default_wasm_path
    config_schema = fetch_value(attrs, [:config_schema, "config_schema"]) || %{}
    display_contract = fetch_value(attrs, [:display_contract, "display_contract"]) || %{}

    with {:ok, repo} <- parse_repo_url(repo_url),
         :ok <- enforce_repo_boundary(repo),
         {:ok, %{sha: sha, verification: verification}} <- resolve_ref(repo, commit),
         {:ok, manifest_map} <- fetch_manifest(repo, sha, manifest_path),
         {:ok, manifest_struct} <- validate_manifest(manifest_map),
         {:ok, wasm} <- fetch_wasm(repo, sha, wasm_path),
         :ok <- enforce_verification_policy(%{verification: verification}) do
      {signature, gpg_verified_at, gpg_key_id, source_commit} =
        verification_metadata(%{verification: verification, sha: sha}, sha)

      {:ok,
       %{
         manifest: manifest_map,
         manifest_struct: manifest_struct,
         config_schema: config_schema,
         display_contract: display_contract,
         wasm: wasm,
         content_hash: Storage.sha256(wasm),
         signature: signature,
         gpg_verified_at: gpg_verified_at,
         gpg_key_id: gpg_key_id,
         source_commit: source_commit
       }}
    end
  end

  def fetch(_), do: {:error, :invalid_attributes}

  @spec fetch_dashboard(map()) :: {:ok, map()} | {:error, term()}
  def fetch_dashboard(attrs) when is_map(attrs) do
    repo_url = fetch_value(attrs, [:source_repo_url, "source_repo_url"])
    commit = fetch_value(attrs, [:source_commit, "source_commit"])

    manifest_path =
      fetch_value(attrs, [:manifest_path, "manifest_path", :source_manifest_path, "source_manifest_path"]) ||
        @default_dashboard_manifest_path

    with {:ok, repo} <- parse_repo_url(repo_url),
         :ok <- enforce_repo_boundary(repo),
         {:ok, %{sha: sha, verification: verification}} <- resolve_ref(repo, commit),
         {:ok, manifest_map, manifest_json, normalized_manifest_path} <-
           fetch_dashboard_manifest(repo, sha, manifest_path),
         {:ok, manifest_struct} <- validate_dashboard_manifest(manifest_map),
         {:ok, renderer_path} <- dashboard_renderer_path(attrs, manifest_struct),
         {:ok, renderer_artifact, normalized_renderer_path} <- fetch_renderer_artifact(repo, sha, renderer_path),
         :ok <- enforce_verification_policy(%{verification: verification}) do
      {signature, gpg_verified_at, gpg_key_id, source_commit} =
        verification_metadata(%{verification: verification, sha: sha}, sha)

      {:ok,
       %{
         manifest: manifest_map,
         manifest_json: manifest_json,
         manifest_struct: manifest_struct,
         renderer_artifact: renderer_artifact,
         content_hash: Storage.sha256(renderer_artifact),
         signature: signature,
         gpg_verified_at: gpg_verified_at,
         gpg_key_id: gpg_key_id,
         source_commit: source_commit,
         source_manifest_path: normalized_manifest_path,
         source_renderer_path: normalized_renderer_path
       }}
    end
  end

  def fetch_dashboard(_), do: {:error, :invalid_attributes}

  defp parse_repo_url(nil), do: {:error, :missing_repo_url}
  defp parse_repo_url(""), do: {:error, :missing_repo_url}

  defp parse_repo_url(url) when is_binary(url) do
    trimmed = String.trim(url)

    https =
      Regex.run(
        ~r/^https?:\/\/github\.com\/([^\/]+)\/([^\/#]+?)(?:\.git)?\/?$/,
        trimmed
      )

    ssh =
      Regex.run(
        ~r/^git@github\.com:([^\/]+)\/(.+?)(?:\.git)?$/,
        trimmed
      )

    cond do
      is_list(https) ->
        [_full, owner, repo] = https
        {:ok, %{owner: owner, repo: repo}}

      is_list(ssh) ->
        [_full, owner, repo] = ssh
        {:ok, %{owner: owner, repo: repo}}

      true ->
        {:error, :invalid_repo_url}
    end
  end

  defp parse_repo_url(_), do: {:error, :invalid_repo_url}

  defp resolve_ref(repo, ref) when is_binary(ref) do
    trimmed = String.trim(ref)

    if trimmed == "" do
      resolve_ref(repo, nil)
    else
      fetch_commit_verification(repo, trimmed)
    end
  end

  defp resolve_ref(repo, _ref) do
    case fetch_default_branch(repo) do
      {:ok, branch} -> fetch_commit_verification(repo, branch)
      {:error, _} -> fetch_commit_verification(repo, "main")
    end
  end

  defp fetch_default_branch(%{owner: owner, repo: repo}) do
    url = "https://api.github.com/repos/#{owner}/#{repo}"

    with {:ok, body} <- github_api_get(url),
         branch when is_binary(branch) <- Map.get(body, "default_branch"),
         true <- branch != "" do
      {:ok, branch}
    else
      _ -> {:error, :default_branch_not_found}
    end
  end

  defp fetch_manifest(repo, ref, path) when is_binary(path) do
    with {:ok, normalized_path} <- normalize_repo_path(path, :invalid_manifest_path),
         {:ok, body} <- fetch_raw(repo, ref, normalized_path),
         {:ok, manifest_map} <- decode_yaml(body) do
      {:ok, manifest_map}
    else
      {:error, errors} when is_list(errors) -> {:error, {:invalid_manifest, errors}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_manifest(_repo, _ref, _path), do: {:error, :invalid_manifest_path}

  defp fetch_wasm(repo, ref, path) when is_binary(path) do
    with {:ok, normalized_path} <- normalize_repo_path(path, :invalid_wasm_path),
         {:ok, body} <- fetch_raw(repo, ref, normalized_path),
         :ok <- ensure_size(body) do
      case body do
        payload when is_binary(payload) -> {:ok, payload}
        payload -> {:ok, to_string(payload)}
      end
    end
  end

  defp fetch_wasm(_repo, _ref, _path), do: {:error, :invalid_wasm_path}

  defp fetch_dashboard_manifest(repo, ref, path) when is_binary(path) do
    with {:ok, normalized_path} <- normalize_repo_path(path, :invalid_manifest_path),
         {:ok, body} <- fetch_raw(repo, ref, normalized_path),
         {:ok, manifest_map} <- decode_json_map(body) do
      {:ok, manifest_map, Jason.encode!(manifest_map), normalized_path}
    else
      {:error, errors} when is_list(errors) -> {:error, {:invalid_manifest, errors}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_dashboard_manifest(_repo, _ref, _path), do: {:error, :invalid_manifest_path}

  defp dashboard_renderer_path(attrs, %DashboardManifest{} = manifest) do
    path =
      fetch_value(attrs, [:renderer_path, "renderer_path", :wasm_path, "wasm_path"]) ||
        manifest.renderer["artifact"]

    case path do
      value when is_binary(value) -> normalize_repo_path(value, :invalid_renderer_path)
      _ -> {:error, :invalid_renderer_path}
    end
  end

  defp fetch_renderer_artifact(repo, ref, path) when is_binary(path) do
    with {:ok, normalized_path} <- normalize_repo_path(path, :invalid_renderer_path),
         {:ok, body} <- fetch_raw(repo, ref, normalized_path),
         :ok <- ensure_size(body) do
      payload = if is_binary(body), do: body, else: to_string(body)
      {:ok, payload, normalized_path}
    end
  end

  defp fetch_renderer_artifact(_repo, _ref, _path), do: {:error, :invalid_renderer_path}

  defp fetch_commit_verification(%{owner: owner, repo: repo}, ref) do
    with {:ok, normalized_ref} <- normalize_ref(ref) do
      url = "https://api.github.com/repos/#{owner}/#{repo}/commits/#{URI.encode_www_form(normalized_ref)}"

      case github_api_get(url) do
        {:ok, body} ->
          sha = Map.get(body, "sha")

          if valid_commit_sha?(sha) do
            {:ok,
             %{
               sha: sha,
               verification: verification_from_body(body)
             }}
          else
            {:error, :invalid_ref}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp verification_from_body(body) when is_map(body) do
    case get_in(body, ["commit", "verification"]) do
      %{} = verification -> verification
      _ -> Map.get(body, "verification") || %{}
    end
  end

  defp verification_metadata(%{verification: verification, sha: sha}, ref) do
    verified = Map.get(verification, "verified") == true
    reason = Map.get(verification, "reason")
    signer = fetch_signer(verification)
    source_commit = sha || ref

    signature =
      drop_blank_values(%{
        "source" => "github",
        "verified" => verified,
        "reason" => reason,
        "signer" => signer,
        "commit" => source_commit
      })

    gpg_verified_at = if verified, do: DateTime.utc_now()
    gpg_key_id = if verified, do: signer

    {signature, gpg_verified_at, gpg_key_id, source_commit}
  end

  defp fetch_signer(verification) when is_map(verification) do
    signer = Map.get(verification, "signer") || %{}

    cond do
      is_binary(Map.get(signer, "login")) -> Map.get(signer, "login")
      is_binary(Map.get(signer, "name")) -> Map.get(signer, "name")
      true -> nil
    end
  end

  defp enforce_verification_policy(%{verification: verification}) do
    policy = verification_policy()
    signer = fetch_signer(verification)

    cond do
      not policy.require_gpg_for_github ->
        :ok

      Map.get(verification, "verified") != true ->
        {:error, :verification_required}

      policy.trusted_github_signers == [] ->
        {:error, :trusted_signers_not_configured}

      signer in policy.trusted_github_signers ->
        :ok

      true ->
        {:error, :untrusted_signer}
    end
  end

  defp verification_policy do
    config = Application.get_env(:serviceradar_web_ng, :plugin_verification, [])

    %{
      require_gpg_for_github: Keyword.get(config, :require_gpg_for_github, false),
      trusted_github_signers:
        config
        |> Keyword.get(:trusted_github_signers, [])
        |> Enum.map(&normalize_signer/1)
        |> Enum.reject(&is_nil/1),
      trusted_github_owners:
        config
        |> Keyword.get(:trusted_github_owners, [])
        |> Enum.map(&normalize_signer/1)
        |> Enum.reject(&is_nil/1),
      trusted_github_repositories:
        config
        |> Keyword.get(:trusted_github_repositories, [])
        |> Enum.map(&normalize_repository/1)
        |> Enum.reject(&is_nil/1)
    }
  end

  defp normalize_signer(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      signer -> String.downcase(signer)
    end
  end

  defp normalize_signer(_value), do: nil

  defp normalize_repository(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      repo -> repo
    end
  end

  defp normalize_repository(_value), do: nil

  defp enforce_repo_boundary(%{owner: owner, repo: repo}) do
    if github_token() in [nil, ""] do
      :ok
    else
      policy = verification_policy()
      normalized_repo = normalize_repository("#{owner}/#{repo}")

      if normalized_repo in policy.trusted_github_repositories or
           String.downcase(owner) in policy.trusted_github_owners do
        :ok
      else
        {:error, :untrusted_repo}
      end
    end
  end

  defp fetch_raw(%{owner: owner, repo: repo}, ref, path) do
    url = "https://raw.githubusercontent.com/#{owner}/#{repo}/#{ref}/#{encode_path(path)}"

    case github_raw_get(url) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp github_api_get(url) do
    headers = github_headers([{<<"accept">>, "application/vnd.github+json"}])
    client = github_http_client()

    case client.get(url, headers: headers) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, :invalid_json}
        end

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp github_raw_get(url) do
    headers = github_headers([])
    client = github_http_client()

    if client == Req do
      github_raw_get_streaming(url, headers)
    else
      github_raw_get_buffered(client, url, headers)
    end
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp github_raw_get_streaming(url, headers) do
    with_secure_download_file("plugin-import", fn tmp_path ->
      case Req.get(url, headers: headers, decode_body: false, into: File.stream!(tmp_path)) do
        {:ok, %Req.Response{status: 200}} ->
          with {:ok, %{size: size}} <- File.stat(tmp_path),
               :ok <- ensure_size(size) do
            File.read(tmp_path)
          end

        {:ok, %Req.Response{status: 404}} ->
          {:error, :not_found}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:http_error, status}}

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  defp github_raw_get_buffered(client, url, headers) do
    case client.get(url, headers: headers, decode_body: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        with :ok <- ensure_size(body) do
          {:ok, body}
        end

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp github_headers(extra) do
    headers = [{"user-agent", "serviceradar"} | extra]

    case github_token() do
      nil -> headers
      "" -> headers
      token -> [{"authorization", "Bearer #{token}"} | headers]
    end
  end

  defp github_token do
    Application.get_env(:serviceradar_web_ng, :github_token) ||
      System.get_env("GITHUB_TOKEN")
  end

  defp github_http_client do
    Application.get_env(:serviceradar_web_ng, :github_http_client, Req)
  end

  defp decode_yaml(body) when is_binary(body) do
    PluginManifest.parse_yaml_map(body)
  end

  defp decode_yaml(_), do: {:error, ["manifest yaml is invalid"]}

  defp decode_json_map(body) when is_binary(body) do
    with {:ok, decoded} <- Jason.decode(body),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      false -> {:error, ["manifest json must decode to an object"]}
      {:error, %Jason.DecodeError{} = error} -> {:error, ["invalid json: #{Exception.message(error)}"]}
    end
  end

  defp decode_json_map(_), do: {:error, ["manifest json is invalid"]}

  defp validate_manifest(manifest_map) do
    case PluginManifest.from_map(manifest_map) do
      {:ok, manifest_struct} -> {:ok, manifest_struct}
      {:error, errors} when is_list(errors) -> {:error, {:invalid_manifest, errors}}
    end
  end

  defp validate_dashboard_manifest(manifest_map) do
    case DashboardManifest.from_map(manifest_map) do
      {:ok, manifest_struct} -> {:ok, manifest_struct}
      {:error, errors} when is_list(errors) -> {:error, {:invalid_manifest, errors}}
    end
  end

  defp ensure_size(payload) when is_binary(payload) do
    ensure_size(byte_size(payload))
  end

  defp ensure_size(size) when is_integer(size) do
    if size > Storage.max_upload_bytes() do
      {:error, :payload_too_large}
    else
      :ok
    end
  end

  defp ensure_size(_payload), do: :ok

  defp normalize_ref(ref) when is_binary(ref) do
    trimmed = String.trim(ref)

    cond do
      trimmed == "" ->
        {:error, :invalid_ref}

      String.length(trimmed) > @max_ref_length ->
        {:error, :invalid_ref}

      String.contains?(trimmed, ["..", "\\", <<0>>]) ->
        {:error, :invalid_ref}

      not Regex.match?(~r/\A[0-9A-Za-z._\-\/]+\z/, trimmed) ->
        {:error, :invalid_ref}

      true ->
        {:ok, trimmed}
    end
  end

  defp valid_commit_sha?(value) when is_binary(value) do
    Regex.match?(~r/\A[0-9a-f]{40}\z/i, value)
  end

  defp valid_commit_sha?(_value), do: false

  defp normalize_repo_path(path, error_atom) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" ->
        {:error, error_atom}

      String.length(trimmed) > @max_path_length ->
        {:error, error_atom}

      String.starts_with?(trimmed, "/") ->
        {:error, error_atom}

      String.contains?(trimmed, ["\\", <<0>>]) ->
        {:error, error_atom}

      true ->
        segments = String.split(trimmed, "/", trim: true)

        if segments == [] or
             Enum.any?(segments, &(&1 in [".", ".."])) or
             Enum.any?(segments, &(not Regex.match?(~r/\A[0-9A-Za-z._\-]+\z/, &1))) do
          {:error, error_atom}
        else
          {:ok, Enum.join(segments, "/")}
        end
    end
  end

  defp encode_path(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map_join("/", &URI.encode_www_form/1)
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp with_secure_download_file(prefix, fun) when is_function(fun, 1) do
    base_dir = Path.join(System.tmp_dir!(), "serviceradar")
    File.mkdir_p!(base_dir)
    do_with_secure_download_file(base_dir, prefix, fun, 5)
  end

  defp do_with_secure_download_file(_base_dir, _prefix, _fun, 0) do
    {:error, :tempfile_allocation_failed}
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp do_with_secure_download_file(base_dir, prefix, fun, attempts_left) do
    random =
      16
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    temp_dir = Path.join(base_dir, "#{prefix}-#{random}")

    case File.mkdir(temp_dir) do
      :ok ->
        tmp_path = Path.join(temp_dir, "download.bin")

        try do
          fun.(tmp_path)
        after
          _ = File.rm_rf(temp_dir)
        end

      {:error, :eexist} ->
        do_with_secure_download_file(base_dir, prefix, fun, attempts_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp fetch_value(_map, _keys), do: nil

  defp drop_blank_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} ->
      is_nil(value) or (is_binary(value) and String.trim(value) == "")
    end)
    |> Map.new()
  end
end
