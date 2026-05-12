defmodule ServiceRadarWebNGWeb.CspReportController do
  @moduledoc """
  Receives browser-generated Content Security Policy violation reports.

  Reports are recorded into the SecurityEvent stream via
  `ServiceRadar.Security.Events.record/1` so they show up in
  Settings → Audit → Events alongside the rest of the stateless
  security signals.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Security.Events

  @max_detail_bytes 4_096

  def create(conn, params) do
    Events.record(%{
      kind: :csp_violation,
      severity: :info,
      ip: client_ip(conn),
      route: conn.request_path,
      details: %{
        "user_agent" => user_agent(conn),
        "report" => truncate(extract_report(params), @max_detail_bytes)
      }
    })

    send_resp(conn, 204, "")
  end

  defp extract_report(%{"csp-report" => report}), do: report
  defp extract_report(%{"report" => report}), do: report
  defp extract_report(other), do: other

  defp client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded |> String.split(",", parts: 2) |> List.first() |> String.trim()

      [] ->
        conn.remote_ip |> :inet.ntoa() |> List.to_string()
    end
  end

  defp user_agent(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      [] -> nil
    end
  end

  defp truncate(report, max) when is_binary(report) do
    if byte_size(report) <= max, do: report, else: binary_part(report, 0, max) <> "…"
  end

  defp truncate(report, max) when is_map(report) do
    json = Jason.encode!(report)
    if byte_size(json) <= max, do: report, else: %{"truncated" => binary_part(json, 0, max)}
  rescue
    _ -> %{"unencodable" => inspect(report)}
  end

  defp truncate(report, max), do: report |> inspect() |> truncate(max)
end
