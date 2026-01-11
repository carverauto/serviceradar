defmodule ServiceRadar.SPIFFE do
  @moduledoc """
  SPIFFE/SPIRE integration for ServiceRadar distributed cluster.

  This module provides helpers for:
  - Loading X.509 SVIDs from SPIRE Workload API or filesystem
  - Verifying SPIFFE IDs for node authorization
  - Configuring TLS options for ERTS distribution
  - Certificate rotation monitoring

  ## SPIFFE ID Format

  ServiceRadar uses SPIFFE IDs in the format:
  ```
  spiffe://serviceradar.local/<node-type>/<partition-id>/<node-id>
  ```

  Where:
  - `node-type` is one of: `core`, `gateway`, `agent`
  - `partition-id` is the partition/tenant identifier
  - `node-id` is the unique node identifier

  ## Configuration

  Configure SPIFFE in your application:

      config :serviceradar_core, :spiffe,
        trust_domain: "serviceradar.local",
        workload_api_socket: "/run/spire/sockets/agent.sock",
        cert_dir: "/etc/serviceradar/certs",
        # Or use filesystem mode for non-SPIRE deployments
        mode: :filesystem  # or :workload_api

  ## Usage

  ```elixir
  # Get TLS options for ERTS distribution
  {:ok, ssl_opts} = ServiceRadar.SPIFFE.ssl_dist_opts()

  # Verify a peer's SPIFFE ID
  {:ok, spiffe_id} = ServiceRadar.SPIFFE.verify_peer_id(peer_cert)
  ```
  """

  require Logger

  @type spiffe_id :: String.t()
  @type node_type :: :core | :gateway | :agent
  @type ssl_opts :: keyword()

  @trust_domain_default "serviceradar.local"
  @cert_dir_default "/etc/serviceradar/certs"

  # SPIFFE ID URI prefix
  @spiffe_uri_prefix "spiffe://"

  @doc """
  Returns SSL/TLS options for ERTS distribution with SPIFFE certificates.

  ## Options

  - `:verify_fun` - Custom verification function (default: SPIFFE ID verification)
  - `:cert_dir` - Directory containing certificates (filesystem mode)
  - `:trust_domain` - Expected SPIFFE trust domain

  ## Returns

  `{:ok, ssl_opts}` or `{:error, reason}`
  """
  @spec ssl_dist_opts(keyword()) :: {:ok, ssl_opts()} | {:error, term()}
  def ssl_dist_opts(opts \\ []) do
    mode = config(:mode, :filesystem)

    case mode do
      :filesystem -> ssl_dist_opts_filesystem(opts)
      :workload_api -> ssl_dist_opts_workload_api(opts)
      other -> {:error, {:invalid_mode, other}}
    end
  end

  @doc """
  Returns SSL/TLS options for client connections (e.g., gRPC to gateways).
  """
  @spec client_ssl_opts(keyword()) :: {:ok, ssl_opts()} | {:error, term()}
  def client_ssl_opts(opts \\ []) do
    with {:ok, base_opts} <- ssl_dist_opts(opts) do
      # Client options don't need server-specific settings
      client_opts =
        base_opts
        |> Keyword.delete(:verify_fun)
        |> Keyword.put(:verify, :verify_peer)

      {:ok, client_opts}
    end
  end

  @doc """
  Returns SSL/TLS options for server connections.
  """
  @spec server_ssl_opts(keyword()) :: {:ok, ssl_opts()} | {:error, term()}
  def server_ssl_opts(opts \\ []) do
    with {:ok, base_opts} <- ssl_dist_opts(opts) do
      server_opts =
        base_opts
        |> Keyword.put(:verify, :verify_peer)
        |> Keyword.put(:fail_if_no_peer_cert, true)

      {:ok, server_opts}
    end
  end

  @doc """
  Extracts and verifies the SPIFFE ID from a peer certificate.

  Returns `{:ok, spiffe_id}` if valid, `{:error, reason}` otherwise.
  """
  @spec verify_peer_id(binary() | tuple()) :: {:ok, spiffe_id()} | {:error, term()}
  def verify_peer_id(cert) when is_binary(cert) do
    case :public_key.pkix_decode_cert(cert, :otp) do
      {:OTPCertificate, _, _, _} = decoded -> verify_peer_id(decoded)
      error -> {:error, {:decode_failed, error}}
    end
  end

  def verify_peer_id({:OTPCertificate, tbs_cert, _, _}) do
    case extract_spiffe_id(tbs_cert) do
      {:ok, spiffe_id} -> verify_spiffe_id(spiffe_id)
      error -> error
    end
  end

  def verify_peer_id(_), do: {:error, :invalid_certificate}

  @doc """
  Parses a SPIFFE ID into its components.

  ## Examples

      iex> ServiceRadar.SPIFFE.parse_spiffe_id("spiffe://serviceradar.local/gateway/partition-1/gateway-001")
      {:ok, %{trust_domain: "serviceradar.local", node_type: :gateway, partition_id: "partition-1", node_id: "gateway-001"}}
  """
  @spec parse_spiffe_id(spiffe_id()) :: {:ok, map()} | {:error, term()}
  def parse_spiffe_id(spiffe_id) when is_binary(spiffe_id) do
    case String.replace_prefix(spiffe_id, @spiffe_uri_prefix, "") do
      ^spiffe_id ->
        {:error, :invalid_spiffe_uri}

      path ->
        case String.split(path, "/", parts: 4) do
          [trust_domain, node_type_str, partition_id, node_id] ->
            with {:ok, node_type} <- parse_node_type(node_type_str) do
              {:ok,
               %{
                 trust_domain: trust_domain,
                 node_type: node_type,
                 partition_id: partition_id,
                 node_id: node_id
               }}
            end

          [trust_domain, node_type_str, node_id] ->
            # Simple format without partition
            with {:ok, node_type} <- parse_node_type(node_type_str) do
              {:ok,
               %{
                 trust_domain: trust_domain,
                 node_type: node_type,
                 partition_id: "default",
                 node_id: node_id
               }}
            end

          _ ->
            {:error, :invalid_spiffe_path}
        end
    end
  end

  @doc """
  Builds a SPIFFE ID from components.

  ## Examples

      iex> ServiceRadar.SPIFFE.build_spiffe_id(:gateway, "partition-1", "gateway-001")
      "spiffe://serviceradar.local/gateway/partition-1/gateway-001"
  """
  @spec build_spiffe_id(node_type(), String.t(), String.t(), keyword()) :: spiffe_id()
  def build_spiffe_id(node_type, partition_id, node_id, opts \\ []) do
    trust_domain = Keyword.get(opts, :trust_domain, config(:trust_domain, @trust_domain_default))
    "#{@spiffe_uri_prefix}#{trust_domain}/#{node_type}/#{partition_id}/#{node_id}"
  end

  @doc """
  Checks if a SPIFFE ID is authorized to connect as a specific node type.
  """
  @spec authorized?(spiffe_id(), node_type()) :: boolean()
  def authorized?(spiffe_id, expected_type) do
    case parse_spiffe_id(spiffe_id) do
      {:ok, %{node_type: ^expected_type, trust_domain: domain}} ->
        domain == config(:trust_domain, @trust_domain_default)

      _ ->
        false
    end
  end

  @doc """
  Returns the certificate directory path.
  """
  @spec cert_dir() :: String.t()
  def cert_dir do
    config(:cert_dir, @cert_dir_default)
  end

  @doc """
  Checks if certificates exist and are readable.
  """
  @spec certs_available?() :: boolean()
  def certs_available? do
    dir = cert_dir()

    File.exists?(Path.join(dir, "svid.pem")) and
      File.exists?(Path.join(dir, "svid-key.pem")) and
      File.exists?(Path.join(dir, "bundle.pem"))
  end

  @doc """
  Returns SPIFFE certificate expiry information.

  Reads the SVID certificate and returns expiration details.
  """
  @spec cert_expiry(keyword()) :: {:ok, map()} | {:error, term()}
  def cert_expiry(opts \\ []) do
    cert_dir = Keyword.get(opts, :cert_dir, cert_dir())
    cert_file = Keyword.get(opts, :cert_file, Path.join(cert_dir, "svid.pem"))

    with {:ok, pem} <- File.read(cert_file),
         {:ok, der} <- extract_der_cert(pem),
         {:ok, validity} <- decode_validity(der),
         {:ok, not_before} <- parse_asn1_time(elem(validity, 1)),
         {:ok, not_after} <- parse_asn1_time(elem(validity, 2)) do
      seconds_remaining = DateTime.diff(not_after, DateTime.utc_now(), :second)
      days_remaining = div(seconds_remaining, 86_400)

      {:ok,
       %{
         not_before: not_before,
         expires_at: not_after,
         seconds_remaining: seconds_remaining,
         days_remaining: days_remaining
       }}
    else
      {:error, _} = error -> error
      error -> {:error, error}
    end
  end

  @doc """
  Monitors certificate files for rotation and returns when they change.

  This is useful for reloading TLS contexts when SPIRE rotates certificates.
  """
  @spec watch_certificates(keyword()) :: {:ok, pid()} | {:error, term()}
  def watch_certificates(opts \\ []) do
    callback = Keyword.get(opts, :callback, fn -> :ok end)
    dir = cert_dir()

    # Use file_system library if available, otherwise poll
    if Code.ensure_loaded?(FileSystem) do
      {:ok, pid} = FileSystem.start_link(dirs: [dir])
      FileSystem.subscribe(pid)

      spawn_link(fn ->
        watch_loop(callback)
      end)

      {:ok, pid}
    else
      # Fallback to polling
      interval = Keyword.get(opts, :poll_interval, 60_000)

      pid =
        spawn_link(fn ->
          poll_certificates(callback, interval, get_cert_mtimes(dir))
        end)

      {:ok, pid}
    end
  end

  # Private functions

  defp ssl_dist_opts_filesystem(opts) do
    dir = Keyword.get(opts, :cert_dir, cert_dir())

    cert_file = Path.join(dir, "svid.pem")
    key_file = Path.join(dir, "svid-key.pem")
    ca_file = Path.join(dir, "bundle.pem")

    cond do
      not File.exists?(cert_file) ->
        {:error, {:cert_not_found, cert_file}}

      not File.exists?(key_file) ->
        {:error, {:key_not_found, key_file}}

      not File.exists?(ca_file) ->
        {:error, {:ca_not_found, ca_file}}

      true ->
        trust_domain =
          Keyword.get(opts, :trust_domain, config(:trust_domain, @trust_domain_default))

        ssl_opts = [
          certfile: String.to_charlist(cert_file),
          keyfile: String.to_charlist(key_file),
          cacertfile: String.to_charlist(ca_file),
          verify: :verify_peer,
          fail_if_no_peer_cert: true,
          verify_fun: {&verify_peer_callback/3, %{trust_domain: trust_domain}},
          depth: 2,
          versions: [:"tlsv1.3", :"tlsv1.2"],
          ciphers: :ssl.cipher_suites(:default, :"tlsv1.3")
        ]

        {:ok, ssl_opts}
    end
  end

  defp ssl_dist_opts_workload_api(_opts) do
    # SPIRE Workload API integration
    # This would use the SPIRE agent's Unix domain socket
    socket_path = config(:workload_api_socket, "/run/spire/sockets/agent.sock")

    if File.exists?(socket_path) do
      Logger.warning("SPIRE Workload API mode not yet implemented, falling back to filesystem")
      ssl_dist_opts_filesystem([])
    else
      {:error, {:workload_api_unavailable, socket_path}}
    end
  end

  defp extract_der_cert(pem) do
    pem
    |> :public_key.pem_decode()
    |> Enum.find(&match?({:Certificate, _, _}, &1))
    |> case do
      {:Certificate, der, _} -> {:ok, der}
      nil -> {:error, :no_certificate}
    end
  end

  defp decode_validity(der) do
    case :public_key.pkix_decode_cert(der, :otp) do
      {:OTPCertificate, tbs_certificate, _sig_alg, _sig} when is_tuple(tbs_certificate) ->
        if tuple_size(tbs_certificate) >= 6 do
          {:ok, elem(tbs_certificate, 5)}
        else
          {:error, {:invalid_certificate, tbs_certificate}}
        end

      other ->
        {:error, {:invalid_certificate, other}}
    end
  end

  defp parse_asn1_time({:utcTime, time}) do
    parse_time_string(List.to_string(time), :utc)
  end

  defp parse_asn1_time({:generalTime, time}) do
    parse_time_string(List.to_string(time), :general)
  end

  defp parse_asn1_time(other) do
    {:error, {:unsupported_time, other}}
  end

  defp parse_time_string(time_str, :utc) do
    case time_str do
      <<yy::binary-size(2), mm::binary-size(2), dd::binary-size(2), hh::binary-size(2),
        mi::binary-size(2), ss::binary-size(2), "Z">> ->
        year = normalize_year(String.to_integer(yy))
        build_datetime(year, mm, dd, hh, mi, ss)

      _ ->
        {:error, {:invalid_time_format, time_str}}
    end
  end

  defp parse_time_string(time_str, :general) do
    case time_str do
      <<yyyy::binary-size(4), mm::binary-size(2), dd::binary-size(2), hh::binary-size(2),
        mi::binary-size(2), ss::binary-size(2), "Z">> ->
        year = String.to_integer(yyyy)
        build_datetime(year, mm, dd, hh, mi, ss)

      _ ->
        {:error, {:invalid_time_format, time_str}}
    end
  end

  defp normalize_year(year) when year < 50, do: 2000 + year
  defp normalize_year(year), do: 1900 + year

  defp build_datetime(year, mm, dd, hh, mi, ss) do
    with {month, ""} <- Integer.parse(mm),
         {day, ""} <- Integer.parse(dd),
         {hour, ""} <- Integer.parse(hh),
         {minute, ""} <- Integer.parse(mi),
         {second, ""} <- Integer.parse(ss),
         {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second),
         {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
      {:ok, datetime}
    else
      _ -> {:error, :invalid_datetime}
    end
  end

  defp verify_peer_callback(cert, event, state) do
    case event do
      {:bad_cert, _reason} = error ->
        {:fail, error}

      {:extension, _} ->
        {:unknown, state}

      :valid ->
        {:valid, state}

      :valid_peer ->
        # Verify the SPIFFE ID in the peer certificate
        case verify_peer_id(cert) do
          {:ok, spiffe_id} ->
            case parse_spiffe_id(spiffe_id) do
              {:ok, %{trust_domain: domain}} when domain == state.trust_domain ->
                Logger.debug("Verified peer SPIFFE ID: #{spiffe_id}")
                {:valid, state}

              {:ok, %{trust_domain: domain}} ->
                Logger.warning("Peer trust domain mismatch: #{domain} != #{state.trust_domain}")
                {:fail, :trust_domain_mismatch}

              {:error, reason} ->
                {:fail, reason}
            end

          {:error, reason} ->
            Logger.warning("Failed to verify peer SPIFFE ID: #{inspect(reason)}")
            {:fail, reason}
        end
    end
  end

  defp extract_spiffe_id(tbs_cert) do
    # Extract the Subject Alternative Name extension which contains the SPIFFE ID
    # The SPIFFE ID is stored as a URI type SAN
    extensions = elem(tbs_cert, 8)

    case find_san_extension(extensions) do
      nil ->
        {:error, :no_san_extension}

      san_ext ->
        case find_uri_san(san_ext) do
          nil -> {:error, :no_uri_san}
          uri -> {:ok, uri}
        end
    end
  end

  defp find_san_extension(extensions) when is_list(extensions) do
    # OID for Subject Alternative Name: 2.5.29.17
    san_oid = {2, 5, 29, 17}

    Enum.find_value(extensions, fn
      {:Extension, ^san_oid, _critical, value} -> value
      _ -> nil
    end)
  end

  defp find_san_extension(_), do: nil

  defp find_uri_san(san_value) when is_list(san_value) do
    Enum.find_value(san_value, fn
      {:uniformResourceIdentifier, uri} when is_list(uri) ->
        uri_str = List.to_string(uri)

        if String.starts_with?(uri_str, @spiffe_uri_prefix) do
          uri_str
        else
          nil
        end

      {:uniformResourceIdentifier, uri} when is_binary(uri) ->
        if String.starts_with?(uri, @spiffe_uri_prefix), do: uri, else: nil

      _ ->
        nil
    end)
  end

  defp find_uri_san(_), do: nil

  defp verify_spiffe_id(spiffe_id) do
    trust_domain = config(:trust_domain, @trust_domain_default)

    case parse_spiffe_id(spiffe_id) do
      {:ok, %{trust_domain: ^trust_domain}} -> {:ok, spiffe_id}
      {:ok, %{trust_domain: other}} -> {:error, {:trust_domain_mismatch, other, trust_domain}}
      error -> error
    end
  end

  defp parse_node_type("core"), do: {:ok, :core}
  defp parse_node_type("gateway"), do: {:ok, :gateway}
  defp parse_node_type("agent"), do: {:ok, :agent}
  defp parse_node_type("web"), do: {:ok, :core}
  defp parse_node_type(other), do: {:error, {:unknown_node_type, other}}

  defp watch_loop(callback) do
    receive do
      {:file_event, _pid, {_path, _events}} ->
        Logger.info("Certificate files changed, triggering reload")
        callback.()
        watch_loop(callback)

      {:file_event, _pid, :stop} ->
        :ok
    end
  end

  defp poll_certificates(callback, interval, last_mtimes) do
    Process.sleep(interval)
    dir = cert_dir()
    current_mtimes = get_cert_mtimes(dir)

    if current_mtimes != last_mtimes do
      Logger.info("Certificate files changed (poll), triggering reload")
      callback.()
    end

    poll_certificates(callback, interval, current_mtimes)
  end

  defp get_cert_mtimes(dir) do
    ["svid.pem", "svid-key.pem", "bundle.pem"]
    |> Enum.map(fn file ->
      path = Path.join(dir, file)

      case File.stat(path) do
        {:ok, %{mtime: mtime}} -> {file, mtime}
        _ -> {file, nil}
      end
    end)
    |> Map.new()
  end

  defp config(key, default) do
    Application.get_env(:serviceradar_core, :spiffe, [])
    |> Keyword.get(key, default)
  end
end
