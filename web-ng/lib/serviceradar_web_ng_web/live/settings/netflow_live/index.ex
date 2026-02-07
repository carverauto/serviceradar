defmodule ServiceRadarWebNGWeb.Settings.NetflowLive.Index do
  @moduledoc """
  Admin-managed NetFlow settings.

  Currently includes:
  - Local CIDRs used for directionality tagging (inbound/outbound/internal/external)
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias AshPhoenix.Form
  alias ServiceRadar.Observability.NetflowLocalCidr
  alias ServiceRadarWebNG.RBAC

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.netflow.manage") do
      {:ok,
       socket
       |> assign(:page_title, "NetFlow Settings")
       |> assign(:current_path, "/settings/netflows")
       |> assign(:cidrs, load_cidrs(scope))
       |> assign(:selected, nil)
       |> assign(:ash_form, nil)
       |> assign(:form, nil)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to manage NetFlow settings")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "NetFlow Settings")
    |> assign(:current_path, "/settings/netflows")
    |> assign(:selected, nil)
    |> assign(:ash_form, nil)
    |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    scope = socket.assigns.current_scope

    ash_form =
      Form.for_create(NetflowLocalCidr, :create, domain: ServiceRadar.Observability, scope: scope)

    socket
    |> assign(:page_title, "Add Local CIDR")
    |> assign(:current_path, "/settings/netflows")
    |> assign(:selected, nil)
    |> assign(:ash_form, ash_form)
    |> assign(:form, to_form(ash_form))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case get_cidr(scope, id) do
      nil ->
        socket
        |> put_flash(:error, "CIDR not found")
        |> push_navigate(to: ~p"/settings/netflows")

      cidr ->
        ash_form =
          Form.for_update(cidr, :update, domain: ServiceRadar.Observability, scope: scope)

        socket
        |> assign(:page_title, "Edit Local CIDR")
        |> assign(:current_path, "/settings/netflows")
        |> assign(:selected, cidr)
        |> assign(:ash_form, ash_form)
        |> assign(:form, to_form(ash_form))
    end
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    ash_form = socket.assigns.ash_form
    ash_form = Form.validate(ash_form, params)

    {:noreply,
     socket
     |> assign(:ash_form, ash_form)
     |> assign(:form, to_form(ash_form))}
  end

  def handle_event("save", %{"form" => params}, socket) do
    ash_form = socket.assigns.ash_form

    case Form.submit(ash_form, params: params) do
      {:ok, _record} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved")
         |> assign(:cidrs, load_cidrs(socket.assigns.current_scope))
         |> push_navigate(to: ~p"/settings/netflows")}

      {:error, ash_form} ->
        {:noreply,
         socket
         |> put_flash(:error, "Validation error")
         |> assign(:ash_form, ash_form)
         |> assign(:form, to_form(ash_form))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case get_cidr(scope, id) do
      nil ->
        {:noreply, socket |> put_flash(:error, "CIDR not found")}

      cidr ->
        case Ash.destroy(cidr, scope: scope) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, "Deleted")
             |> assign(:cidrs, load_cidrs(scope))}

          {:error, err} ->
            {:noreply, socket |> put_flash(:error, format_ash_error(err))}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path="/settings/netflows">
        <div class="space-y-4">
          <.settings_nav current_path="/settings/netflows" current_scope={@current_scope} />
          <.network_nav current_path="/settings/netflows" current_scope={@current_scope} />
        </div>

        <div class="grid gap-6 lg:grid-cols-[1fr,520px]">
          <section class="space-y-4">
            <div>
              <h1 class="text-xl font-semibold">NetFlow</h1>
              <p class="text-sm text-base-content/60">
                Configure directionality tagging based on local networks. These CIDRs are used by SRQL
                queries and enrichment pipelines to label flows as inbound/outbound/internal/external.
              </p>
            </div>

            <div class="flex items-center justify-between">
              <h2 class="text-sm font-semibold">Local CIDRs</h2>
              <.link navigate={~p"/settings/netflows/new"} class="btn btn-sm btn-primary">
                Add CIDR
              </.link>
            </div>

            <div class="overflow-x-auto rounded-xl border border-base-200 bg-base-100">
              <table class="table">
                <thead>
                  <tr>
                    <th>Partition</th>
                    <th>Label</th>
                    <th>CIDR</th>
                    <th>Status</th>
                    <th class="text-right">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for cidr <- @cidrs do %>
                    <tr id={"cidr-#{cidr.id}"}>
                      <td class="font-mono text-xs">{cidr.partition || "*"}</td>
                      <td>{cidr.label || ""}</td>
                      <td class="font-mono text-xs">{cidr.cidr}</td>
                      <td>
                        <span class={[
                          "badge badge-sm",
                          (cidr.enabled && "badge-success") || "badge-ghost"
                        ]}>
                          {if(cidr.enabled, do: "enabled", else: "disabled")}
                        </span>
                      </td>
                      <td class="text-right space-x-2">
                        <.link navigate={~p"/settings/netflows/#{cidr.id}/edit"} class="btn btn-xs">
                          Edit
                        </.link>
                        <button
                          type="button"
                          class="btn btn-xs btn-ghost text-error"
                          phx-click="delete"
                          phx-value-id={cidr.id}
                          data-confirm="Delete this CIDR?"
                        >
                          Delete
                        </button>
                      </td>
                    </tr>
                  <% end %>
                  <%= if Enum.empty?(@cidrs) do %>
                    <tr>
                      <td colspan="5" class="text-sm text-base-content/60">
                        No CIDRs configured yet.
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </section>

          <section class="space-y-4">
            <div class="rounded-xl border border-base-200 bg-base-100 p-4">
              <h2 class="text-sm font-semibold">Directionality</h2>
              <p class="text-xs text-base-content/60 mt-1">
                Flows are labeled using the configured CIDRs:
              </p>
              <ul class="mt-3 text-xs text-base-content/80 list-disc pl-5 space-y-1">
                <li><span class="font-semibold">internal</span>: src and dst are local</li>
                <li><span class="font-semibold">outbound</span>: src is local, dst is not</li>
                <li><span class="font-semibold">inbound</span>: src is not local, dst is local</li>
                <li><span class="font-semibold">external</span>: neither is local</li>
              </ul>
              <div class="mt-4 rounded-lg bg-base-200/60 p-3 text-xs">
                Partition scope: set <span class="font-mono">partition</span> to apply only to that
                partition; leave blank to apply globally.
              </div>
            </div>

            <%= if @form do %>
              <div class="rounded-xl border border-base-200 bg-base-100 p-4">
                <h2 class="text-sm font-semibold">
                  {if(@selected, do: "Edit CIDR", else: "Add CIDR")}
                </h2>

                <.form for={@form} id="netflow-cidr-form" phx-change="validate" phx-submit="save">
                  <div class="space-y-3 mt-3">
                    <.input field={@form[:partition]} type="text" label="Partition (optional)" />
                    <.input field={@form[:label]} type="text" label="Label (optional)" />
                    <.input field={@form[:cidr]} type="text" label="CIDR" placeholder="10.0.0.0/8" />
                    <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
                  </div>

                  <div class="mt-5 flex items-center justify-between">
                    <.link navigate={~p"/settings/netflows"} class="btn btn-ghost btn-sm">
                      Cancel
                    </.link>
                    <button class="btn btn-primary btn-sm" type="submit">Save</button>
                  </div>
                </.form>
              </div>
            <% else %>
              <div class="rounded-xl border border-base-200 bg-base-100 p-4">
                <h2 class="text-sm font-semibold">Add CIDRs</h2>
                <p class="text-xs text-base-content/60 mt-1">
                  Use the button on the left to add local networks for directionality tagging.
                </p>
              </div>
            <% end %>
          </section>
        </div>
      </.settings_shell>
    </Layouts.app>
    """
  end

  defp load_cidrs(scope) do
    query =
      NetflowLocalCidr
      |> Ash.Query.for_read(:list, %{})
      |> Ash.Query.sort(enabled: :desc, partition: :asc, cidr: :asc)

    case Ash.read(query, scope: scope) do
      {:ok, %Ash.Page.Keyset{} = page} -> page.results
      {:ok, rows} when is_list(rows) -> rows
      _ -> []
    end
  end

  defp get_cidr(scope, id) do
    query =
      NetflowLocalCidr
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(id == ^id)

    case Ash.read_one(query, scope: scope) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  defp format_ash_error(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, ", ", fn
      %{message: message} -> message
      _ -> "Validation error"
    end)
  end

  defp format_ash_error(_), do: "Unexpected error"
end
