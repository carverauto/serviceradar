defmodule ServiceRadar.Credentials.ProxmoxApiSmoke do
  @moduledoc """
  Direct Proxmox API smoke test helper for local credential validation.

  This path is intentionally independent of edge agents. Operators can provide
  Proxmox API details through environment variables and run a local ExUnit smoke
  test or Mix task from `elixir/serviceradar_core`.
  """

  @default_timeout_ms 30_000

  @type config :: %{
          base_url: String.t(),
          api_token: String.t(),
          timeout_ms: pos_integer(),
          insecure_skip_verify: boolean()
        }

  @type result :: %{
          schema: String.t(),
          base_url: String.t(),
          version: map() | nil,
          node_count: non_neg_integer(),
          nodes: [map()]
        }

  @doc """
  Builds a Proxmox smoke-test config from environment variables.

  Supported variables:

  - `SERVICERADAR_PROXMOX_URL`, required
  - `SERVICERADAR_PROXMOX_API_TOKEN`, either a full `PVEAPIToken=...` header
    value or the raw `user@realm!tokenid=secret` token
  - `SERVICERADAR_PROXMOX_TOKEN_ID` plus `SERVICERADAR_PROXMOX_TOKEN_SECRET`,
    alternative to `SERVICERADAR_PROXMOX_API_TOKEN`
  - `SERVICERADAR_PROXMOX_INSECURE_SKIP_VERIFY`, optional boolean
  - `SERVICERADAR_PROXMOX_TIMEOUT_MS`, optional positive integer
  """
  @spec from_env(keyword()) :: {:ok, config()} | {:error, term()}
  def from_env(opts \\ []) do
    env = Keyword.get(opts, :env, &System.get_env/1)

    with {:ok, base_url} <- fetch_env(env, "SERVICERADAR_PROXMOX_URL"),
         {:ok, api_token} <- api_token_from_env(env) do
      {:ok,
       %{
         base_url: normalize_base_url(base_url),
         api_token: proxmox_api_token_header(api_token),
         timeout_ms:
           "SERVICERADAR_PROXMOX_TIMEOUT_MS"
           |> env.()
           |> positive_int(@default_timeout_ms),
         insecure_skip_verify:
           "SERVICERADAR_PROXMOX_INSECURE_SKIP_VERIFY"
           |> env.()
           |> truthy?()
       }}
    end
  end

  @spec env_configured?(keyword()) :: boolean()
  def env_configured?(opts \\ []) do
    match?({:ok, _config}, from_env(opts))
  end

  @spec run(config(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(%{base_url: base_url, api_token: _api_token} = config, opts \\ []) do
    request = Keyword.get(opts, :request, &default_request/4)

    with {:ok, version} <- get_json(request, config, "/api2/json/version"),
         {:ok, nodes} <- get_json(request, config, "/api2/json/nodes") do
      node_rows = data_list(nodes)

      {:ok,
       %{
         schema: "serviceradar.proxmox_api_smoke.v1",
         base_url: base_url,
         version: data_map(version),
         node_count: length(node_rows),
         nodes: Enum.map(node_rows, &redacted_node/1)
       }}
    end
  rescue
    exception -> {:error, exception}
  end

  defp get_json(request, config, path) do
    url = config.base_url <> path

    headers = [
      {"authorization", config.api_token},
      {"accept", "application/json"}
    ]

    opts = req_opts(config)

    case request.(url, headers, opts, config) do
      {:ok, %{status: status, body: body}} when status >= 200 and status < 300 ->
        {:ok, normalize_body(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, redacted_error_body(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_request(url, headers, opts, _config) do
    Req.get(url, Keyword.put(opts, :headers, headers))
  end

  defp req_opts(config) do
    opts = [
      receive_timeout: config.timeout_ms,
      connect_options: [timeout: config.timeout_ms],
      redirect: false
    ]

    if config.insecure_skip_verify do
      Keyword.update!(opts, :connect_options, fn connect_options ->
        Keyword.put(connect_options, :transport_opts, verify: :verify_none)
      end)
    else
      opts
    end
  end

  defp api_token_from_env(env) do
    case trim(env.("SERVICERADAR_PROXMOX_API_TOKEN")) do
      "" ->
        with {:ok, token_id} <- fetch_env(env, "SERVICERADAR_PROXMOX_TOKEN_ID"),
             {:ok, secret} <- fetch_env(env, "SERVICERADAR_PROXMOX_TOKEN_SECRET") do
          {:ok, "#{token_id}=#{secret}"}
        end

      token ->
        {:ok, token}
    end
  end

  defp fetch_env(env, key) do
    case trim(env.(key)) do
      "" -> {:error, {:missing_env, key}}
      value -> {:ok, value}
    end
  end

  defp proxmox_api_token_header(token) do
    token = trim(token)

    if String.starts_with?(token, "PVEAPIToken=") do
      token
    else
      "PVEAPIToken=" <> token
    end
  end

  defp normalize_base_url(value) do
    value = trim(value)

    cond do
      value == "" ->
        ""

      String.starts_with?(value, ["http://", "https://"]) ->
        String.trim_trailing(value, "/")

      true ->
        "https://" <> String.trim_trailing(value, "/") <> ":8006"
    end
  end

  defp normalize_body(body) when is_map(body), do: body

  defp normalize_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp normalize_body(_body), do: %{}

  defp data_map(%{"data" => data}) when is_map(data), do: data
  defp data_map(%{data: data}) when is_map(data), do: data
  defp data_map(_body), do: nil

  defp data_list(%{"data" => data}) when is_list(data), do: data
  defp data_list(%{data: data}) when is_list(data), do: data
  defp data_list(_body), do: []

  defp redacted_node(node) when is_map(node) do
    Map.take(node, ["node", "status", "cpu", "maxcpu", "mem", "maxmem", "uptime"])
  end

  defp redacted_node(_node), do: %{}

  defp redacted_error_body(body) when is_binary(body), do: String.slice(body, 0, 256)

  defp redacted_error_body(body) when is_map(body),
    do: Map.drop(body, ["ticket", "token", "password", "secret"])

  defp redacted_error_body(_body), do: nil

  defp positive_int(value, default) do
    case Integer.parse(trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp truthy?(value), do: String.downcase(trim(value)) in ["1", "true", "yes", "y", "on"]

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()
end
