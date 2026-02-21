defmodule ServiceRadarWebNGWeb.ClientIP do
  @moduledoc """
  Centralized client IP extraction.

  Security default: do not trust `x-forwarded-for` unless explicitly enabled via config.

      config :serviceradar_web_ng, :client_ip,
        trust_x_forwarded_for: true
  """

  import Plug.Conn

  @xff_header "x-forwarded-for"

  @spec get(Plug.Conn.t()) :: String.t()
  def get(%Plug.Conn{} = conn) do
    remote = conn.remote_ip |> :inet.ntoa() |> to_string()

    if trust_x_forwarded_for?() do
      case get_req_header(conn, @xff_header) do
        [forwarded | _] ->
          forwarded
          |> String.split(",", parts: 2)
          |> List.first()
          |> to_string()
          |> String.trim()
          |> valid_ip_or(remote)

        _ ->
          remote
      end
    else
      remote
    end
  end

  defp trust_x_forwarded_for? do
    Application.get_env(:serviceradar_web_ng, :client_ip, [])
    |> Keyword.get(:trust_x_forwarded_for, false)
  end

  defp valid_ip_or(ip, fallback) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, _} -> ip
      {:error, _} -> fallback
    end
  end
end
