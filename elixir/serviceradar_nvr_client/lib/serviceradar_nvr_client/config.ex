defmodule ServiceRadarNVRClient.Config do
  @moduledoc "Installed workload credentials. No camera credentials or request-selected URL."
  @derive {Inspect, except: [:token]}
  @enforce_keys [:host, :port, :ca, :cert, :key, :token]
  defstruct @enforce_keys

  def load(config_path, token_path) do
    with {:ok, bytes} <- read(config_path, 32_768),
         {:ok, %{"host" => host, "port" => port, "ca_file" => ca, "cert_file" => cert, "key_file" => key} = fields} <-
           Jason.decode(bytes),
         true <- map_size(fields) == 5,
         {:ok, token} <- read(token_path, 512),
         config = %__MODULE__{host: host, port: port, ca: ca, cert: cert, key: key, token: token},
         :ok <- validate(config) do
      {:ok, config}
    else
      _ -> {:error, :invalid_ingest_config}
    end
  end

  def validate(%__MODULE__{} = config) do
    if valid_host?(config.host) and config.port in 1..65_535 and valid_token?(config.token) and
         Enum.all?([config.ca, config.cert, config.key], &(is_binary(&1) and Path.type(&1) == :absolute)),
       do: :ok,
       else: {:error, :invalid_ingest_config}
  end

  defp valid_host?(host), do: is_binary(host) and byte_size(host) in 1..253 and Regex.match?(~r/\A[a-zA-Z0-9.-]+\z/, host)

  defp valid_token?(token), do: is_binary(token) and byte_size(token) in 32..512 and Regex.match?(~r/\A[!-~]+\z/, token)

  @doc false
  def read(path, limit) when is_binary(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, limit + 1)) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= limit -> {:ok, bytes}
      _ -> {:error, :invalid_ingest_config}
    end
  end

  def read(_, _), do: {:error, :invalid_ingest_config}
end
