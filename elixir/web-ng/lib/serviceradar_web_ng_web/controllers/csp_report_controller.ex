defmodule ServiceRadarWebNGWeb.CspReportController do
  @moduledoc """
  Receives browser-generated Content Security Policy violation reports.

  Until `ServiceRadar.Security.SecurityEvent` (added in section 6 of the
  platform-security-hardening change) lands, reports are logged at
  `info` level with a `csp_violation` tag so they can be aggregated in
  the log pipeline. Once `SecurityEvent` exists, the body of this
  controller swaps to `ServiceRadar.Security.Events.record/1` so reports
  show up in Settings → Audit → Events alongside the rest of the
  stateless security stream.
  """

  use ServiceRadarWebNGWeb, :controller

  require Logger

  @max_log_bytes 2_048

  def create(conn, params) do
    report = extract_report(params)

    Logger.info("csp_violation",
      ip: client_ip(conn),
      user_agent: user_agent(conn),
      report: truncate(inspect(report), @max_log_bytes)
    )

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

  defp truncate(string, max) when byte_size(string) <= max, do: string
  defp truncate(string, max), do: binary_part(string, 0, max) <> "…"
end
