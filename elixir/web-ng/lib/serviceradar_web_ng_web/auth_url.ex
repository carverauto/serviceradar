defmodule ServiceRadarWebNGWeb.AuthURL do
  @moduledoc false

  @spec password_reset_url(String.t()) :: String.t()
  def password_reset_url(token) when is_binary(token) do
    ServiceRadarWebNGWeb.Endpoint.url() <> "/auth/password-reset/" <> URI.encode(token)
  end
end
