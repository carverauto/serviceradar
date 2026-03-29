defmodule ServiceRadarWebNG.Plugins.GitHubImporter do
  @moduledoc """
  Fetches plugin packages from GitHub repositories.
  """

  alias ServiceRadar.Plugins.Manifest
  alias ServiceRadarWebNG.Plugins.Storage

  @default_manifest_path "plugin.yaml"
  @default_wasm_path "plugin.wasm"

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
         {:ok, ref} <- resolve_ref(repo, commit),
         {:ok, manifest_map} <- fetch_manifest(repo, ref, manifest_path),
         {:ok, manifest_struct} <- validate_manifest(manifest_map),
         {:ok, wasm} <- fetch_wasm(repo, ref, wasm_path),
         :ok <- ensure_size(wasm),
         {:ok, commit_meta} <- fetch_commit_verification(repo, ref),
         :ok <- enforce_verification_policy(commit_meta) do
      {signature, gpg_verified_at, gpg_key_id, source_commit} =
        verification_metadata(commit_meta, ref)

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
      {:ok, trimmed}
    end
  end

  defp resolve_ref(repo, _ref) do
    case fetch_default_branch(repo) do
      {:ok, branch} -> {:ok, branch}
      {:error, _} -> {:ok, "main"}
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
    case fetch_raw(repo, ref, path) do
      {:ok, body} -> decode_yaml(body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_manifest(_repo, _ref, _path), do: {:error, :invalid_manifest_path}

  defp fetch_wasm(repo, ref, path) when is_binary(path) do
    case fetch_raw(repo, ref, path) do
      {:ok, body} when is_binary(body) -> {:ok, body}
      {:ok, body} -> {:ok, to_string(body)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_wasm(_repo, _ref, _path), do: {:error, :invalid_wasm_path}

  defp fetch_commit_verification(%{owner: owner, repo: repo}, ref) do
    url = "https://api.github.com/repos/#{owner}/#{repo}/commits/#{ref}"

    case github_api_get(url) do
      {:ok, body} ->
        {:ok,
         %{
           sha: Map.get(body, "sha"),
           verification: verification_from_body(body)
         }}

      {:error, reason} ->
        {:ok, %{sha: nil, verification: %{"verified" => false, "reason" => reason}}}
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

  defp fetch_raw(%{owner: owner, repo: repo}, ref, path) do
    url = "https://raw.githubusercontent.com/#{owner}/#{repo}/#{ref}/#{path}"

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

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp github_raw_get(url) do
    headers = github_headers([])

    client = github_http_client()

    case client.get(url, headers: headers, decode_body: false) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: 404}} -> {:error, :not_found}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_error, status}}
      {:error, error} -> {:error, error}
    end
  end

  defp github_headers(extra) do
    headers = [{"user-agent", "serviceradar"} | extra]

    case github_token() do
      nil -> headers
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
    case YamlElixir.read_from_string(body) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {:invalid_yaml, reason}}
    end
  rescue
    error -> {:error, {:invalid_yaml, error}}
  end

  defp decode_yaml(_), do: {:error, :invalid_yaml}

  defp validate_manifest(manifest_map) do
    case Manifest.from_map(manifest_map) do
      {:ok, manifest_struct} -> {:ok, manifest_struct}
      {:error, errors} when is_list(errors) -> {:error, {:invalid_manifest, errors}}
    end
  end

  defp ensure_size(payload) when is_binary(payload) do
    if byte_size(payload) > Storage.max_upload_bytes() do
      {:error, :payload_too_large}
    else
      :ok
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
