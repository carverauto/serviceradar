defmodule ServiceRadarWebNG.Plugins.GitHubImporter do
  @moduledoc """
  Fetches plugin and dashboard packages from GitHub repositories.
  """

  alias ServiceRadar.Dashboards.Manifest, as: DashboardManifest
  alias ServiceRadar.Plugins.DisplayContract
  alias ServiceRadar.Plugins.Manifest, as: PluginManifest
  alias ServiceRadarWebNG.Packages.RepoClient
  alias ServiceRadarWebNG.Plugins.Storage

  @default_manifest_path "plugin.yaml"
  @default_wasm_path "plugin.wasm"
  @default_dashboard_manifest_path "dashboard.json"

  @spec fetch(map()) :: {:ok, map()} | {:error, term()}
  def fetch(attrs) when is_map(attrs) do
    repo_url = fetch_value(attrs, [:source_repo_url, "source_repo_url"])
    commit = fetch_value(attrs, [:source_commit, "source_commit"])

    manifest_path =
      fetch_value(attrs, [:manifest_path, "manifest_path"]) || @default_manifest_path

    wasm_path = fetch_value(attrs, [:wasm_path, "wasm_path"]) || @default_wasm_path
    config_schema = fetch_value(attrs, [:config_schema, "config_schema"]) || %{}
    display_contract = fetch_value(attrs, [:display_contract, "display_contract"]) || %{}
    display_contracts = fetch_value(attrs, [:display_contracts, "display_contracts"]) || %{}

    with {:ok, contracts} <- validate_display_contracts(display_contracts),
         {:ok, repo} <- RepoClient.parse_repo_url(repo_url),
         :ok <- RepoClient.enforce_repo_boundary(repo, http_opts()),
         {:ok, %{sha: sha, verification: verification}} <- RepoClient.resolve_ref(repo, commit, http_opts()),
         {:ok, manifest_map} <- fetch_manifest(repo, sha, manifest_path),
         {:ok, manifest_struct} <- validate_manifest(manifest_map),
         {:ok, wasm} <- fetch_wasm(repo, sha, wasm_path),
         :ok <- RepoClient.enforce_verification_policy(%{verification: verification}) do
      {signature, gpg_verified_at, gpg_key_id, source_commit} =
        RepoClient.verification_metadata(%{verification: verification, sha: sha}, sha)

      {:ok,
       %{
         manifest: manifest_map,
         manifest_struct: manifest_struct,
         config_schema: config_schema,
         display_contract: display_contract,
         display_contracts: contracts,
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

    with {:ok, repo} <- RepoClient.parse_repo_url(repo_url),
         :ok <- RepoClient.enforce_repo_boundary(repo, http_opts()),
         {:ok, %{sha: sha, verification: verification}} <- RepoClient.resolve_ref(repo, commit, http_opts()),
         {:ok, manifest_map, manifest_json, normalized_manifest_path} <-
           fetch_dashboard_manifest(repo, sha, manifest_path),
         {:ok, manifest_struct} <- validate_dashboard_manifest(manifest_map),
         {:ok, renderer_path} <- dashboard_renderer_path(attrs, manifest_struct),
         {:ok, renderer_artifact, normalized_renderer_path} <- fetch_renderer_artifact(repo, sha, renderer_path),
         :ok <- RepoClient.enforce_verification_policy(%{verification: verification}) do
      {signature, gpg_verified_at, gpg_key_id, source_commit} =
        RepoClient.verification_metadata(%{verification: verification, sha: sha}, sha)

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

  # A GitHub import carries no bundle, so any display contracts arrive as
  # caller-supplied attributes. They are validated on the same path a bundle's
  # are, so an operator-pasted contract cannot reach the packages table with
  # looser rules than one that shipped inside a signed artifact.
  defp validate_display_contracts(documents) do
    case DisplayContract.validate_all(documents) do
      {:ok, contracts} -> {:ok, contracts}
      {:error, errors} -> {:error, {:invalid_display_contract, errors}}
    end
  end

  defp fetch_manifest(repo, ref, path) when is_binary(path) do
    with {:ok, normalized_path} <- RepoClient.normalize_repo_path(path, :invalid_manifest_path),
         {:ok, body} <- RepoClient.fetch_raw(repo, ref, normalized_path, http_opts()),
         {:ok, manifest_map} <- decode_yaml(body) do
      {:ok, manifest_map}
    else
      {:error, errors} when is_list(errors) -> {:error, {:invalid_manifest, errors}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_manifest(_repo, _ref, _path), do: {:error, :invalid_manifest_path}

  defp fetch_wasm(repo, ref, path) when is_binary(path) do
    with {:ok, normalized_path} <- RepoClient.normalize_repo_path(path, :invalid_wasm_path),
         {:ok, body} <- RepoClient.fetch_raw(repo, ref, normalized_path, http_opts()),
         :ok <- ensure_size(body) do
      case body do
        payload when is_binary(payload) -> {:ok, payload}
        payload -> {:ok, to_string(payload)}
      end
    end
  end

  defp fetch_wasm(_repo, _ref, _path), do: {:error, :invalid_wasm_path}

  defp fetch_dashboard_manifest(repo, ref, path) when is_binary(path) do
    with {:ok, normalized_path} <- RepoClient.normalize_repo_path(path, :invalid_manifest_path),
         {:ok, body} <- RepoClient.fetch_raw(repo, ref, normalized_path, http_opts()),
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
      value when is_binary(value) -> RepoClient.normalize_repo_path(value, :invalid_renderer_path)
      _ -> {:error, :invalid_renderer_path}
    end
  end

  defp fetch_renderer_artifact(repo, ref, path) when is_binary(path) do
    with {:ok, normalized_path} <- RepoClient.normalize_repo_path(path, :invalid_renderer_path),
         {:ok, body} <- RepoClient.fetch_raw(repo, ref, normalized_path, http_opts()),
         :ok <- ensure_size(body) do
      payload = if is_binary(body), do: body, else: to_string(body)
      {:ok, payload, normalized_path}
    end
  end

  defp fetch_renderer_artifact(_repo, _ref, _path), do: {:error, :invalid_renderer_path}

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

  defp fetch_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp fetch_value(_map, _keys), do: nil

  # Returns keyword opts passed to every RepoClient call.
  # Default HTTP client is EgressClient; tests override via :github_http_client.
  defp http_opts do
    client = Application.get_env(:serviceradar_web_ng, :github_http_client, ServiceRadar.HTTP.EgressClient)
    [http_client: client]
  end
end
