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
  alias ServiceRadarWebNGWeb.ClientIP

  @max_detail_bytes 4_096
  @max_body_bytes 16_384

  def create(conn, params) do
    {conn, params} = report_params(conn, params)

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

  # Browsers post a `report-uri` violation as `application/csp-report`, which the
  # endpoint's JSON parser does not claim, so the body arrives unread and the
  # params are empty. Read and decode it here, bounded by @max_body_bytes.
  defp report_params(conn, params) when map_size(params) > 0, do: {conn, params}

  defp report_params(conn, _params) do
    with {:ok, body, conn} <- Plug.Conn.read_body(conn, length: @max_body_bytes),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body) do
      {conn, decoded}
    else
      {:more, _partial, conn} -> {conn, %{"unreadable" => "report larger than #{@max_body_bytes} bytes"}}
      _other -> {conn, %{"unreadable" => "report is not a JSON object"}}
    end
  end

  defp extract_report(%{"csp-report" => report}), do: report
  defp extract_report(%{"report" => report}), do: report
  defp extract_report(other), do: other

  # Centralized extraction: honors x-forwarded-for only from trusted
  # proxies (see ServiceRadarWebNG.ClientIP).
  defp client_ip(conn), do: ClientIP.get(conn)

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
