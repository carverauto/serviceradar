defmodule ServiceRadarWebNG.Audit.DashboardRendererEvents do
  @moduledoc """
  Audit events for dashboard renderer blob requests.

  HTTP responses stay 404 for both missing and forbidden packages so the
  endpoint does not disclose restricted dashboards. The audit trail records
  the distinction.
  """

  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadarWebNG.ClientIP

  require Logger

  @spec record(Plug.Conn.t(), String.t(), :served | :not_found | :forbidden, map()) :: :ok
  def record(%Plug.Conn{} = conn, package_id, result, attrs \\ %{})
      when is_binary(package_id) and result in [:served, :not_found, :forbidden] do
    actor_user = conn.assigns[:current_user] || actor_from_scope(conn.assigns[:current_scope])

    details =
      attrs
      |> Map.put(:ip, ClientIP.get(conn))
      |> Map.put(:result, result)
      |> Map.put(:package_id, package_id)

    AuditWriter.write_async(
      action: :read,
      resource_type: "dashboard_package_renderer",
      resource_id: package_id,
      resource_name: Map.get(attrs, :dashboard_id) || package_id,
      actor: actor_user,
      details: details
    )

    :ok
  rescue
    error ->
      Logger.warning("DashboardRendererEvents.record/4 raised: #{inspect(error)} result=#{inspect(result)}")
      :ok
  end

  defp actor_from_scope(%{user: %{} = user}), do: user
  defp actor_from_scope(_), do: nil
end
