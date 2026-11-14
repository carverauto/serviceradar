defmodule ServiceRadarNVR.IngestListener do
  @moduledoc """
  Opt-in private TLS input for trusted recording coordinators.

  The installed client certificate pin and separate token identify ServiceRadar
  workloads, not cameras. The coordinator must hold recording authority and
  exclusive source ownership before submitting media. This listener does not
  enroll recorders, initialize storage or grant catalog availability.
  """

  alias ServiceRadarNVR.DeliveryConfig

  def load(env) do
    case {env["SERVICERADAR_NVR_INGEST_CONFIG_FILE"], env["SERVICERADAR_NVR_INGEST_TOKEN_FILE"]} do
      {nil, nil} -> {:ok, nil}
      {config, token} when is_binary(config) and is_binary(token) -> read(config, token)
      _ -> {:error, :invalid_nvr_ingest_config}
    end
  end

  def child_spec(config) do
    installation = config.ingest

    Supervisor.child_spec(
      {Bandit,
       plug: {ServiceRadarNVR.Ingest, config},
       scheme: :https,
       ip: {0, 0, 0, 0},
       port: installation.port,
       certfile: installation.cert,
       keyfile: installation.key,
       http_1_options: [max_requests: 1],
       http_2_options: [enabled: false],
       thousand_island_options: [
         num_acceptors: 2,
         num_connections: 8,
         transport_options: [
           cacertfile: installation.ca,
           verify: :verify_peer,
           fail_if_no_peer_cert: true,
           versions: [:"tlsv1.3", :"tlsv1.2"]
         ]
       ]},
      id: __MODULE__
    )
  end

  defp read(config_path, token_path) do
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
      _ -> {:error, :invalid_nvr_ingest_config}
    end
  end
end
