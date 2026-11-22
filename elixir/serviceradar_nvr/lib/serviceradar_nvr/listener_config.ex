defmodule ServiceRadarNVR.ListenerConfig do
  @moduledoc """
  Installed configuration and authentication shared by the private TLS listeners.

  Each listener reads a 5-key JSON document (`port`, `ca_file`, `cert_file`,
  `key_file`, `client_sha256`) and a separate bearer token file. A request is
  authenticated only by a TLS peer certificate whose SHA-256 equals the pinned
  `client_sha256` and by its bearer token, compared by digest. The pin and token
  identify ServiceRadar workloads, not cameras or users.
  """

  import Plug.Conn

  alias ServiceRadarNVR.DeliveryConfig

  @doc "Reads one listener's installation; `{:ok, nil}` when neither file is configured."
  def load(env, config_key, token_key, error) do
    case {env[config_key], env[token_key]} do
      {nil, nil} -> {:ok, nil}
      {config, token} when is_binary(config) and is_binary(token) -> read(config, token, error)
      _ -> {:error, error}
    end
  end

  @doc "Bandit child for `plug` on the installation's port, HTTP/1 only, one request per connection."
  def child_spec(installation, plug, id, connections) do
    Supervisor.child_spec(
      {Bandit,
       plug: plug,
       scheme: :https,
       ip: {0, 0, 0, 0},
       port: installation.port,
       certfile: installation.cert,
       keyfile: installation.key,
       http_1_options: [max_requests: 1],
       http_2_options: [enabled: false],
       thousand_island_options: [
         num_acceptors: 2,
         num_connections: connections,
         transport_options: [
           cacertfile: installation.ca,
           verify: :verify_peer,
           fail_if_no_peer_cert: true,
           versions: [:"tlsv1.3", :"tlsv1.2"]
         ]
       ]},
      id: id
    )
  end

  @doc "True only for an HTTPS request from the pinned client certificate with the installation's token."
  def authorized?(conn, installation) do
    with :https <- conn.scheme,
         %{ssl_cert: certificate} when is_binary(certificate) <- get_peer_data(conn),
         true <- :crypto.hash(:sha256, certificate) == installation.client_sha256,
         ["Bearer " <> token] when byte_size(token) <= 512 <- get_req_header(conn, "authorization") do
      Plug.Crypto.secure_compare(:crypto.hash(:sha256, token), installation.token_sha256)
    else
      _ -> false
    end
  end

  defp read(config_path, token_path, error) do
    with {:ok, bytes} <- DeliveryConfig.bounded_read(config_path, 4096),
         {:ok, document} when is_map(document) and map_size(document) == 5 <- Jason.decode(bytes),
         %{"port" => port, "ca_file" => ca, "cert_file" => cert, "key_file" => key, "client_sha256" => pin} <- document,
         true <- is_integer(port) and port in 1..65_535,
         true <- Enum.all?([ca, cert, key], &(is_binary(&1) and Path.type(&1) == :absolute)),
         true <- is_binary(pin) and byte_size(pin) == 64,
         {:ok, pin} <- Base.decode16(pin, case: :lower),
         {:ok, token} <- DeliveryConfig.bounded_read(token_path, 512),
         true <- byte_size(token) in 32..512 and Regex.match?(~r/\A[!-~]+\z/, token) do
      {:ok, %{port: port, ca: ca, cert: cert, key: key, client_sha256: pin, token_sha256: :crypto.hash(:sha256, token)}}
    else
      _ -> {:error, error}
    end
  end
end
