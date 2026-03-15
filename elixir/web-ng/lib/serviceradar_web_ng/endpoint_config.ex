defmodule ServiceRadarWebNG.EndpointConfig do
  @moduledoc false

  @endpoint ServiceRadarWebNGWeb.Endpoint

  @spec base_url() :: String.t()
  def base_url do
    @endpoint.url()
  end

  @spec secret_key_base() :: String.t()
  def secret_key_base do
    case Application.get_env(:serviceradar_web_ng, @endpoint)[:secret_key_base] do
      secret when is_binary(secret) and byte_size(secret) > 0 -> secret
      _ -> raise "secret_key_base must be configured"
    end
  end
end
