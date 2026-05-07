defmodule ServiceRadarWebNG.Audit.DashboardPublishEvents do
  @moduledoc """
  Emit audit events for the API-driven dashboard-package lifecycle:
  publish, enable, disable.

  Wraps `ServiceRadar.Events.AuditWriter.write_async/1` so the publish
  controller can emit one structured event per hop without coupling the
  controller to the NATS-shaped audit envelope. Calls are best-effort —
  a downstream NATS outage SHALL NOT fail the publish itself.

  The shape lines up with the requirements in the
  `add-cli-dashboard-publish-api` spec:

      %{
        actor_user_id: "...",
        jti: "...",
        action: :dashboard_publish | :dashboard_enable | :dashboard_disable,
        dashboard_id: "...",
        version: "...",
        route_slug: "..." | nil,
        content_hash: "...",
        ip: "...",
        result: :written | :idempotent_noop | :rejected,
        reason: "..." | nil
      }
  """

  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadarWebNG.ClientIP

  require Logger

  @type action :: :dashboard_publish | :dashboard_enable | :dashboard_disable
  @type result :: :written | :idempotent_noop | :rejected

  @spec record(Plug.Conn.t(), action(), map()) :: :ok
  def record(%Plug.Conn{} = conn, action, attrs) when is_atom(action) and is_map(attrs) do
    actor_user = conn.assigns[:current_user] || actor_from_scope(conn.assigns[:current_scope])
    jti = jti_from_conn(conn)
    ip = ClientIP.get(conn)

    details =
      attrs
      |> Map.put_new(:ip, ip)
      |> Map.put(:jti, jti)
      |> Map.put(:action, action)

    AuditWriter.write_async(
      action: audit_action(action),
      resource_type: "dashboard_package",
      resource_id: Map.get(attrs, :package_id) || "n/a",
      resource_name: build_resource_name(attrs) || "unknown",
      actor: actor_user,
      details: details
    )

    :ok
  rescue
    error ->
      Logger.warning("DashboardPublishEvents.record/3 raised: #{inspect(error)} action=#{inspect(action)}")

      :ok
  end

  defp audit_action(:dashboard_publish), do: :create
  defp audit_action(:dashboard_enable), do: :update
  defp audit_action(:dashboard_disable), do: :update

  defp build_resource_name(%{dashboard_id: id, version: version}) when is_binary(id), do: "#{id}@#{version || "?"}"

  defp build_resource_name(%{dashboard_id: id}) when is_binary(id), do: id
  defp build_resource_name(%{package: %DashboardPackage{dashboard_id: id, version: v}}), do: "#{id}@#{v}"

  defp build_resource_name(_), do: nil

  defp actor_from_scope(%{user: %{} = user}), do: user
  defp actor_from_scope(_), do: nil

  defp jti_from_conn(conn) do
    cond do
      is_binary(conn.assigns[:jwt_jti]) -> conn.assigns[:jwt_jti]
      is_binary(conn.assigns[:cli_session_jti]) -> conn.assigns[:cli_session_jti]
      true -> nil
    end
  end
end
