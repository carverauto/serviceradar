defmodule ServiceRadarWebNGWeb.Plugs.AutomationCallbackRequestGuard do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  @denied ~s({"error":"callback_denied"})
  @quality_value ~r/\A(?:0(?:\.\d{0,3})?|1(?:\.0{0,3})?)\z/
  @zero_quality ~r/\A0(?:\.0{0,3})?\z/

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if json_content_type?(conn) and json_acceptable?(conn) do
      conn
    else
      conn
      |> put_resp_header("content-type", "application/json")
      |> send_resp(401, @denied)
      |> halt()
    end
  end

  defp json_content_type?(conn) do
    case get_req_header(conn, "content-type") do
      [value] ->
        value
        |> String.split(";", parts: 2)
        |> List.first()
        |> String.trim()
        |> String.downcase()
        |> Kernel.==("application/json")

      _ ->
        false
    end
  end

  defp json_acceptable?(conn) do
    case get_req_header(conn, "accept") do
      [] -> true
      [value] -> json_accept_value?(String.downcase(value))
      _ -> false
    end
  end

  defp json_accept_value?(value) do
    value
    |> String.split(",")
    |> Enum.any?(&acceptable_json_range?/1)
  end

  defp acceptable_json_range?(range) do
    [media_type | parameters] = String.split(range, ";")

    String.trim(media_type) in ["*/*", "application/*", "application/json"] and
      positive_quality?(parameters)
  end

  defp positive_quality?(parameters) do
    quality_values =
      parameters
      |> Enum.map(fn parameter ->
        case String.split(parameter, "=", parts: 2) do
          [name, quality] -> {String.trim(name), String.trim(quality)}
          [name] -> {String.trim(name), nil}
        end
      end)
      |> Enum.filter(&(elem(&1, 0) == "q"))
      |> Enum.map(&elem(&1, 1))

    case quality_values do
      [] ->
        true

      [quality] when is_binary(quality) ->
        Regex.match?(@quality_value, quality) and not Regex.match?(@zero_quality, quality)

      _ ->
        false
    end
  end
end
