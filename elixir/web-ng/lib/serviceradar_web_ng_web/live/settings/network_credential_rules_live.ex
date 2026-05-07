defmodule ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLive do
  @moduledoc """
  Network credential rules settings index.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadarWebNG.RBAC

  require Ash.Query

  @current_path "/settings/networks/credentials"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if can_manage?(scope) do
      {:ok,
       socket
       |> assign(:page_title, "Credential Rules")
       |> assign(:current_path, @current_path)
       |> assign(:rules, load_rules(scope))}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to manage credential rules")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path={@current_path}>
        <div class="space-y-4">
          <.settings_nav current_path={@current_path} current_scope={@current_scope} />
          <.network_nav current_path={@current_path} current_scope={@current_scope} />
        </div>

        <section class="space-y-4">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h1 class="text-xl font-semibold">Credential Rules</h1>
            </div>
          </div>

          <div class="overflow-hidden rounded-lg border border-base-200 bg-base-100">
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Provider</th>
                    <th>Purpose</th>
                    <th>Scope</th>
                    <th>Priority</th>
                    <th>Status</th>
                    <th>Last Test</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :if={@rules == []}>
                    <td colspan="7" class="py-8 text-center text-sm text-base-content/60">
                      No credential rules found.
                    </td>
                  </tr>
                  <tr :for={rule <- @rules}>
                    <td class="font-medium">{rule.name}</td>
                    <td>{rule.provider}</td>
                    <td>{format_atom(rule.purpose)}</td>
                    <td>{format_scope(rule)}</td>
                    <td>{rule.priority}</td>
                    <td>
                      <span class={[
                        "badge badge-sm",
                        if(rule.enabled, do: "badge-success", else: "badge-ghost")
                      ]}>
                        {if rule.enabled, do: "Enabled", else: "Disabled"}
                      </span>
                    </td>
                    <td>{format_atom(rule.last_test_status) || "Not tested"}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </section>
      </.settings_shell>
    </Layouts.app>
    """
  end

  defp load_rules(scope) do
    NetworkCredentialRule
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.sort(priority: :asc, inserted_at: :asc)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, rules} -> rules
      _ -> []
    end
  end

  defp can_manage?(scope), do: RBAC.can?(scope, "settings.credentials.manage")

  defp format_scope(rule), do: "#{format_atom(rule.scope_type)}: #{rule.scope_value}"

  defp format_atom(nil), do: nil

  defp format_atom(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  defp format_atom(value), do: to_string(value)
end
