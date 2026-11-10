defmodule ServiceRadarNVR.DeliveryConfig do
  @moduledoc "Installed, boot-time credentials for the private Core publication receiver."

  @derive {Inspect, except: [:token]}
  defstruct [:host, :port, :ca, :cert, :key, :token]

  def load(env) do
    case {env["SERVICERADAR_NVR_PUBLICATION_CONFIG_FILE"], env["SERVICERADAR_NVR_PUBLICATION_TOKEN_FILE"]} do
      {nil, nil} -> {:ok, nil}
      {config, token} when is_binary(config) and is_binary(token) -> read(config, token)
      _ -> {:error, :invalid_nvr_delivery_config}
    end
  end

  defp read(config_path, token_path) do
    with {:ok, bytes} <- bounded_read(config_path, 32_768),
         {:ok, config} when is_map(config) and map_size(config) == 5 <- Jason.decode(bytes),
         %{"host" => host, "port" => port, "ca_file" => ca, "cert_file" => cert, "key_file" => key} <- config,
         true <- is_binary(host) and byte_size(host) in 1..253 and Regex.match?(~r/\A[a-zA-Z0-9.-]+\z/, host),
         true <- is_integer(port) and port in 1..65_535,
         true <- Enum.all?([ca, cert, key], &(is_binary(&1) and Path.type(&1) == :absolute)),
         {:ok, token} <- bounded_read(token_path, 512),
         token = String.trim(token),
         true <- byte_size(token) in 32..512 and Regex.match?(~r/\A[!-~]+\z/, token) do
      {:ok, %__MODULE__{host: host, port: port, ca: ca, cert: cert, key: key, token: token}}
    else
      _ -> {:error, :invalid_nvr_delivery_config}
    end
  end

  @doc false
  def bounded_read(path, limit) do
    case File.open(path, [:read, :binary], &IO.binread(&1, limit + 1)) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= limit -> {:ok, bytes}
      _ -> {:error, :invalid_nvr_delivery_config}
    end
  end
end
