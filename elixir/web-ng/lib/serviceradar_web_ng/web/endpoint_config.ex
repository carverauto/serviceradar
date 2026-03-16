defmodule ServiceRadarWebNG.Web.EndpointConfig do
  @moduledoc false

  @spec base_url() :: String.t()
  def base_url do
    apply(endpoint_module(), :url, [])
  end

  @spec http_config() :: keyword() | nil
  def http_config do
    apply(endpoint_module(), :config, [:http])
  end

  @spec internal_base_url() :: String.t()
  def internal_base_url do
    http = http_config()

    if is_list(http) do
      port = Keyword.get(http, :port, 4000)
      "http://127.0.0.1:#{port}"
    else
      base_url()
    end
  end

  @spec secret_key_base() :: String.t()
  def secret_key_base do
    case Application.get_env(:serviceradar_web_ng, endpoint_module())[:secret_key_base] do
      secret when is_binary(secret) and byte_size(secret) > 0 -> secret
      _ -> raise "secret_key_base must be configured"
    end
  end

  defp endpoint_module do
    Module.concat(["ServiceRadarWebNGWeb", "Endpoint"])
  end
end
