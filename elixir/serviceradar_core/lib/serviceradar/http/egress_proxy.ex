defmodule ServiceRadar.HTTP.EgressProxy do
  @moduledoc """
  Shared CONNECT-proxy settings for `ServiceRadar.Finch` and
  `ServiceRadar.HTTP.EgressClient`.

  `SERVICERADAR_EGRESS_PROXY` is an HTTP URL (`http://host:port`). When set,
  release runtime configuration stores it as `:serviceradar_core, :egress_proxy`.
  Finch pools and `EgressClient` use that host as an HTTP CONNECT proxy so a
  default-deny NetworkPolicy can allow only the proxy. Unset leaves new clients
  connecting directly. See `ServiceRadar.HTTP.EgressClient` for the external
  artifact streaming contract and CONNECT compatibility constraints.

  HTTPS proxy URLs are rejected: Mint's CONNECT proxy is itself HTTP.
  """

  @env "SERVICERADAR_EGRESS_PROXY"

  @type t :: %{scheme: :http, host: String.t(), port: pos_integer()}

  @doc """
  Parse a proxy URL.

  Returns `nil` for blank input. Raises `ArgumentError` for a value that is
  set but not an `http://host[:port]` URL.
  """
  @spec parse(nil | String.t()) :: t() | nil
  def parse(nil), do: nil
  def parse(""), do: nil

  def parse(value) when is_binary(value) do
    case URI.parse(String.trim(value)) do
      %URI{scheme: "http", host: host, port: port}
      when is_binary(host) and host != "" and is_integer(port) and port > 0 ->
        %{scheme: :http, host: host, port: port}

      %URI{scheme: "https"} ->
        raise ArgumentError,
              "#{@env} must be an HTTP CONNECT proxy (http://host:port), not HTTPS"

      _other ->
        raise ArgumentError,
              "#{@env} must be an HTTP CONNECT proxy URL (http://host:port), got: #{inspect(value)}"
    end
  end

  @doc "Read `#{@env}` from an environment map (or `System.get_env/0`)."
  @spec from_env(map() | Enumerable.t()) :: t() | nil
  def from_env(env \\ System.get_env()) do
    parse(env_get(env, @env))
  end

  @doc """
  Finch `:pools` map, including CAStore transport opts when available.

  `nil` pools means Finch's defaults (no proxy).
  """
  @spec finch_pools(t() | nil) :: map() | nil
  def finch_pools(proxy \\ Application.get_env(:serviceradar_core, :egress_proxy)) do
    conn_opts =
      []
      |> maybe_put_cacert()
      |> maybe_put_proxy(proxy)

    case conn_opts do
      [] -> nil
      opts -> %{default: [conn_opts: opts]}
    end
  end

  @doc """
  Req options that use the named `ServiceRadar.Finch` pool.

  Req 0.7 raises `ArgumentError` if a request sets both `:finch` and
  `:connect_options`. Connect/TLS/proxy belong on the pool (`finch_pools/1`).
  Callers that need per-request TLS (SNI-to-IP, `verify: :verify_none`) must
  drop `:finch` instead of combining the two.

  Do not install these via `Req.default_options/1`. A process-wide `:finch`
  default makes every remaining `connect_options:` call site crash at run
  time — that is what failed `BumblebeeCatalogRefreshWorkerTest` on s7
  after #5003.
  """
  @spec req_opts(pos_integer()) :: keyword()
  def req_opts(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    [receive_timeout: timeout_ms, retry: false, finch: [name: ServiceRadar.Finch]]
  end

  defp maybe_put_cacert(conn_opts) do
    if Code.ensure_loaded?(CAStore) and function_exported?(CAStore, :file_path, 0) do
      Keyword.put(conn_opts, :transport_opts, cacertfile: CAStore.file_path())
    else
      conn_opts
    end
  end

  defp maybe_put_proxy(conn_opts, %{scheme: :http, host: host, port: port}) do
    Keyword.put(conn_opts, :proxy, {:http, host, port, []})
  end

  defp maybe_put_proxy(conn_opts, _), do: conn_opts

  defp env_get(env, key) when is_map(env), do: Map.get(env, key)

  defp env_get(env, key) do
    case Enum.find(env, fn {name, _} -> name == key end) do
      {^key, value} -> value
      _ -> nil
    end
  end
end
