defmodule ServiceRadarWebNGWeb.Api.AnsibleAutomationController do
  @moduledoc "Authenticated JSON access to canonical Ansible operations and reviewed authority."
  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AnsibleAutomation
  alias ServiceRadarWebNG.RBAC

  plug(:authorize)

  def index(conn, params), do: respond(conn, automation().list_operations(scope(conn), params))
  def show(conn, %{"id" => id}), do: respond(conn, automation().get_operation(scope(conn), id))
  def prepare(conn, params), do: respond(conn, automation().prepare(scope(conn), params))
  def create(conn, params), do: respond(conn, automation().launch(scope(conn), params), :accepted)

  def cancel(conn, %{"id" => id}), do: respond(conn, automation().request_cancel(scope(conn), id), :accepted)

  def memberships(conn, params), do: respond(conn, automation().list_memberships(scope(conn), params))

  def bindings(conn, params), do: respond(conn, automation().list_bindings(scope(conn), params))

  def approve_membership(conn, %{"id" => id} = params) do
    respond(conn, automation().approve_membership(scope(conn), id, Map.delete(params, "id")))
  end

  def prepare_binding(conn, params), do: respond(conn, automation().prepare_binding(scope(conn), params))

  def create_binding(conn, params), do: respond(conn, automation().create_binding(scope(conn), params), :created)

  def revoke_binding(conn, %{"id" => id} = params),
    do: respond(conn, automation().revoke_binding(scope(conn), id, Map.delete(params, "id")))

  defp authorize(conn, _opts) do
    action = action_name(conn)

    cond do
      not match?(%Scope{user: %{id: _}}, scope(conn)) ->
        deny(conn, :unauthorized, "unauthorized")

      human_action?(action) and not is_nil(conn.assigns[:oauth_client_id]) ->
        deny(conn, :forbidden, "human_principal_required")

      not RBAC.can?(scope(conn), permission(action)) ->
        deny(conn, :forbidden, "forbidden")

      true ->
        conn
    end
  end

  defp human_action?(action),
    do: action in [:prepare, :create, :cancel, :approve_membership, :prepare_binding, :create_binding, :revoke_binding]

  defp permission(action) when action in [:prepare, :create], do: "ansible.runs.launch"
  defp permission(:cancel), do: "ansible.runs.cancel"

  defp permission(action) when action in [:approve_membership, :prepare_binding, :create_binding, :revoke_binding],
    do: "ansible.controllers.manage"

  defp permission(:bindings), do: "ansible.catalog.view"
  defp permission(_action), do: "ansible.runs.view"

  defp respond(conn, result, status \\ :ok)
  defp respond(conn, {:ok, value}, status), do: conn |> put_status(status) |> json(value)

  defp respond(conn, {:error, :cancellation_not_implemented}, _status),
    do: deny(conn, :not_implemented, "cancellation_not_implemented")

  defp respond(conn, {:error, reason}, _status) when reason in [:unauthorized, :forbidden, :not_found],
    do: deny(conn, reason, Atom.to_string(reason))

  defp respond(conn, {:error, reason}, _status) when is_atom(reason),
    do: deny(conn, :unprocessable_entity, Atom.to_string(reason))

  defp respond(conn, {:error, _reason}, _status), do: deny(conn, :unprocessable_entity, "ansible_request_rejected")

  defp deny(conn, status, code), do: conn |> put_status(status) |> json(%{error: code}) |> halt()
  defp scope(conn), do: conn.assigns[:current_scope]

  defp automation, do: Application.get_env(:serviceradar_web_ng, :ansible_automation, AnsibleAutomation)
end
