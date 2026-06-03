defmodule ServiceRadarWebNGWeb.Admin.AddonPackageLive.Index do
  @moduledoc """
  Edge Ops LiveView for native agent add-ons (feature sets, issue 3425).

  Operators browse approved add-on packages, configure one from its
  config.schema.json, and assign it to an agent (creating an AddonAssignment that
  the control plane compiles into the agent config and pushes down). The catalog
  and assignment writes go through the web-ng context modules which wrap the
  serviceradar_core ServiceRadar.Plugins.Addon* Ash resources.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.PluginConfigForm
  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadar.AgentRuntimeMetadata
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadarWebNG.Plugins.AddonAssignments
  alias ServiceRadarWebNG.Plugins.AddonPackages
  alias ServiceRadarWebNG.RBAC

  require Ash.Query

  @cohort_options [
    {"Connected Agents", "connected"},
    {"Custom Agent IDs", "custom"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "plugins.view") do
      {:ok,
       socket
       |> assign(:can_assign_addons, RBAC.can?(scope, "plugins.assign"))
       |> assign(:can_review_addons, RBAC.can?(scope, "settings.plugins.manage"))
       |> assign(:page_title, "Add-ons")
       |> assign(:current_path, nil)
       |> assign(:addons_base_path, "/settings/agents/addons")
       |> assign(:packages, list_addon_packages(scope))
       |> assign(:agents, list_agents(scope))
       |> assign(:cohort_options, @cohort_options)
       |> assign(:show_details_modal, false)
       |> assign(:selected_package, nil)
       |> assign(:assignments, [])
       |> assign(:assignment_preview, empty_assignment_preview())
       |> assign(:assignment_form, default_assignment_form())}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to access Add-ons.")
       |> redirect(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_params(params, url, socket) do
    socket =
      socket
      |> assign(:current_path, current_path_from_url(url))
      |> assign(:addons_base_path, addons_base_path_from_url(url))

    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:show_details_modal, false)
    |> assign(:selected_package, nil)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case AddonPackages.get(id, scope: scope) do
      {:ok, package} ->
        socket
        |> assign(:selected_package, package)
        |> assign(:show_details_modal, true)
        |> assign(:assignment_form, default_assignment_form())
        |> assign(:assignment_preview, build_assignment_preview(default_assignment_form(), package, scope))
        |> assign(:assignments, list_assignments_for_package(package.id, scope))

      _ ->
        socket
        |> put_flash(:error, "Add-on not found.")
        |> push_navigate(to: socket.assigns.addons_base_path)
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :packages, list_addon_packages(socket.assigns.current_scope))}
  end

  def handle_event("view_package", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: socket.assigns.addons_base_path <> "/" <> id)}
  end

  def handle_event("close_details", _params, socket) do
    {:noreply, push_patch(socket, to: socket.assigns.addons_base_path)}
  end

  def handle_event("assignment_change", %{"assignment" => form}, socket) do
    form = Map.merge(default_assignment_form(), form)

    {:noreply,
     socket
     |> assign(:assignment_form, form)
     |> assign(
       :assignment_preview,
       build_assignment_preview(form, socket.assigns.selected_package, socket.assigns.current_scope)
     )}
  end

  def handle_event("create_assignment", _params, %{assigns: %{can_assign_addons: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to assign add-ons.")}
  end

  def handle_event("create_assignment", %{"assignment" => form}, socket) do
    scope = socket.assigns.current_scope
    package = socket.assigns.selected_package
    form = Map.merge(default_assignment_form(), form)

    with {:ok, agent_uids} <- fetch_assignment_agent_uids(form, package, scope),
         {:ok, params} <- parse_params(form, package.config_schema) do
      case create_assignments(agent_uids, package, params, parse_args(Map.get(form, "args")), scope) do
        {:ok, count} ->
          {:noreply,
           socket
           |> put_flash(:info, assignment_success_message(count))
           |> assign(:assignments, list_assignments_for_package(package.id, scope))
           |> assign(:assignment_form, default_assignment_form())
           |> assign(:assignment_preview, build_assignment_preview(default_assignment_form(), package, scope))}

        {:error, error, _created_count} ->
          {:noreply, put_flash(socket, :error, "Failed to assign: #{format_error(error)}")}
      end
    else
      {:error, :missing_agent} ->
        {:noreply, put_flash(socket, :error, "Select an agent.")}

      {:error, :empty_cohort} ->
        {:noreply, put_flash(socket, :error, "The selected cohort has no compatible agents.")}

      {:error, {:invalid_params, message}} ->
        {:noreply, put_flash(socket, :error, "Invalid configuration: #{message}")}
    end
  end

  def handle_event("approve_package", %{"id" => id, "review" => form}, socket) do
    scope = socket.assigns.current_scope
    package = socket.assigns.selected_package
    approved_capabilities = parse_selected_capabilities(form)

    cond do
      not socket.assigns.can_review_addons ->
        {:noreply, put_flash(socket, :error, "You don't have permission to review add-ons.")}

      package_capabilities(package) != [] and approved_capabilities == [] ->
        {:noreply, put_flash(socket, :error, "Select at least one approved capability.")}

      true ->
        attrs = %{approved_capabilities: approved_capabilities}

        case AddonPackages.approve(id, attrs,
               scope: scope,
               approved_by: approved_by(socket.assigns.current_scope)
             ) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> put_flash(:info, "Add-on approved.")
             |> assign(:packages, list_addon_packages(scope))
             |> assign(:selected_package, updated)
             |> assign(:assignment_preview, build_assignment_preview(socket.assigns.assignment_form, updated, scope))}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, "Failed to approve: #{format_error(error)}")}
        end
    end
  end

  def handle_event("deny_package", %{"id" => id, "review" => form}, socket) do
    scope = socket.assigns.current_scope

    if socket.assigns.can_review_addons do
      attrs = %{denied_reason: present_text(Map.get(form, "denied_reason"))}

      case AddonPackages.deny(id, attrs, scope: scope) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> put_flash(:info, "Add-on denied.")
           |> assign(:packages, list_addon_packages(scope))
           |> assign(:selected_package, updated)}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, "Failed to deny: #{format_error(error)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to review add-ons.")}
    end
  end

  def handle_event("delete_assignment", _params, %{assigns: %{can_assign_addons: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to manage add-ons.")}
  end

  def handle_event("delete_assignment", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    package = socket.assigns.selected_package

    case AddonAssignments.delete(id, scope: scope) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> put_flash(:info, "Assignment removed.")
         |> assign(:assignments, list_assignments_for_package(package.id, scope))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed to remove: #{format_error(error)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path={@current_path || @addons_base_path}>
        <.settings_nav
          current_path={@current_path || @addons_base_path}
          current_scope={@current_scope}
        />
        <.edge_nav
          current_path={@current_path || @addons_base_path}
          class="mt-2"
          current_scope={@current_scope}
        />

        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">Add-ons</h1>
            <p class="text-sm text-base-content/60">
              Select native agent add-ons (feature sets) and push them down to your agents.
            </p>
          </div>
          <.ui_button variant="ghost" size="sm" phx-click="refresh">
            <.icon name="hero-arrow-path" class="size-4" /> Refresh
          </.ui_button>
        </div>

        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">Available add-ons</div>
              <p class="text-xs text-base-content/60">
                Staged packages need review before assignment; approved packages can be targeted.
              </p>
            </div>
          </:header>

          <%= if @packages == [] do %>
            <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-8 text-center">
              <div class="text-sm font-semibold text-base-content">No approved add-ons</div>
              <p class="mt-1 text-xs text-base-content/60">
                Approved add-on packages appear here once imported and reviewed.
              </p>
            </div>
          <% else %>
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-base-content/60">
                    <th>Add-on</th>
                    <th>Version</th>
                    <th>Delivery</th>
                    <th>Capabilities</th>
                    <th>Status</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for package <- @packages do %>
                    <tr class="hover:bg-base-200/30">
                      <td>
                        <div class="font-medium">{package.name}</div>
                        <div class="text-xs text-base-content/60 font-mono">{package.addon_id}</div>
                      </td>
                      <td class="text-xs">{package.version}</td>
                      <td class="text-xs">{package.delivery}</td>
                      <td class="text-xs">{Enum.join(package.capabilities || [], ", ")}</td>
                      <td>
                        <span class={["badge badge-sm", package_status_badge(package.status)]}>
                          {package.status}
                        </span>
                      </td>
                      <td class="text-right">
                        <.ui_button
                          variant="ghost"
                          size="sm"
                          phx-click="view_package"
                          phx-value-id={package.id}
                        >
                          View
                        </.ui_button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </.ui_panel>

        <%= if @show_details_modal and @selected_package do %>
          <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
            <div class="w-full max-w-4xl rounded-2xl bg-base-100 p-6 shadow-xl space-y-4 overflow-y-auto max-h-[90vh]">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <h2 class="text-lg font-semibold text-base-content">{@selected_package.name}</h2>
                  <div class="text-xs text-base-content/60 font-mono">
                    {@selected_package.addon_id} · v{@selected_package.version}
                  </div>
                </div>
                <.ui_button variant="ghost" size="sm" phx-click="close_details">Close</.ui_button>
              </div>

              <dl class="grid grid-cols-2 gap-2 text-xs">
                <div>
                  <dt class="text-base-content/60">Delivery</dt>
                  <dd>{@selected_package.delivery}</dd>
                </div>
                <div>
                  <dt class="text-base-content/60">Supervision</dt>
                  <dd>{@selected_package.supervision}</dd>
                </div>
                <div class="col-span-2">
                  <dt class="text-base-content/60">Capabilities</dt>
                  <dd>{Enum.join(@selected_package.capabilities || [], ", ")}</dd>
                </div>
                <div class="col-span-2">
                  <dt class="text-base-content/60">Approved capabilities</dt>
                  <dd>{approved_capabilities_text(@selected_package)}</dd>
                </div>
              </dl>

              <div class="grid gap-3 md:grid-cols-2">
                <div class="rounded-xl border border-base-200 p-4 space-y-2">
                  <div class="text-sm font-semibold">Manifest & delivery</div>
                  <dl class="grid grid-cols-2 gap-2 text-xs">
                    <div>
                      <dt class="text-base-content/60">Kind</dt>
                      <dd>{@selected_package.kind}</dd>
                    </div>
                    <div>
                      <dt class="text-base-content/60">Binary</dt>
                      <dd class="font-mono">{@selected_package.binary || "—"}</dd>
                    </div>
                    <div class="col-span-2">
                      <dt class="text-base-content/60">Install path</dt>
                      <dd class="font-mono break-all">{@selected_package.install_path}</dd>
                    </div>
                    <div class="col-span-2">
                      <dt class="text-base-content/60">Supported artifacts</dt>
                      <dd class="flex flex-wrap gap-1">
                        <%= for platform <- addon_supported_platforms(@selected_package) do %>
                          <span class="badge badge-ghost badge-xs font-mono">{platform}</span>
                        <% end %>
                        <span
                          :if={addon_supported_platforms(@selected_package) == []}
                          class="text-base-content/50"
                        >
                          No per-architecture artifact gate
                        </span>
                      </dd>
                    </div>
                  </dl>
                </div>

                <div class="rounded-xl border border-base-200 p-4 space-y-2">
                  <div class="text-sm font-semibold">Provenance</div>
                  <dl class="space-y-2 text-xs">
                    <div>
                      <dt class="text-base-content/60">Source</dt>
                      <dd>{@selected_package.source_type}</dd>
                    </div>
                    <div>
                      <dt class="text-base-content/60">Release</dt>
                      <dd class="font-mono">{@selected_package.source_release_tag || "—"}</dd>
                    </div>
                    <div>
                      <dt class="text-base-content/60">OCI reference</dt>
                      <dd class="font-mono break-all">{@selected_package.source_oci_ref || "—"}</dd>
                    </div>
                    <div>
                      <dt class="text-base-content/60">Digest</dt>
                      <dd class="font-mono break-all">
                        {@selected_package.source_oci_digest || "—"}
                      </dd>
                    </div>
                    <div>
                      <dt class="text-base-content/60">Verification</dt>
                      <dd>{@selected_package.verification_status || "—"}</dd>
                    </div>
                  </dl>
                </div>
              </div>

              <div
                :if={@selected_package.status == :staged}
                class="rounded-xl border border-warning/30 bg-warning/5 p-4 space-y-3"
              >
                <div class="text-sm font-semibold">Approval review</div>
                <p class="text-xs text-base-content/60">
                  Approve only the capabilities this add-on should be allowed to expose.
                </p>

                <form
                  id={"approve-addon-#{@selected_package.id}"}
                  phx-submit="approve_package"
                  phx-value-id={@selected_package.id}
                  class="space-y-3"
                >
                  <div class="flex flex-wrap gap-2">
                    <%= for cap <- package_capabilities(@selected_package) do %>
                      <label class="inline-flex items-center gap-2 rounded-lg border border-base-200 px-3 py-2 text-xs">
                        <input
                          type="checkbox"
                          name="review[approved_capabilities][]"
                          value={cap}
                          checked
                          class="checkbox checkbox-xs"
                        />
                        <span class="font-mono">{cap}</span>
                      </label>
                    <% end %>
                    <span
                      :if={package_capabilities(@selected_package) == []}
                      class="text-xs text-base-content/60"
                    >
                      This package declares no capabilities.
                    </span>
                  </div>
                  <div class="flex flex-wrap justify-end gap-2">
                    <button
                      :if={@can_review_addons}
                      type="submit"
                      class="btn btn-primary btn-sm"
                    >
                      Approve
                    </button>
                  </div>
                </form>

                <form
                  id={"deny-addon-#{@selected_package.id}"}
                  phx-submit="deny_package"
                  phx-value-id={@selected_package.id}
                  class="space-y-2"
                >
                  <label class="label"><span class="label-text">Deny reason</span></label>
                  <textarea
                    name="review[denied_reason]"
                    class="textarea textarea-bordered w-full text-sm min-h-[64px]"
                    placeholder="Reason this package should not be assigned"
                  ></textarea>
                  <div class="flex justify-end">
                    <button
                      :if={@can_review_addons}
                      type="submit"
                      class="btn btn-error btn-sm"
                    >
                      Deny
                    </button>
                  </div>
                </form>
              </div>

              <div
                :if={@selected_package.status in [:denied, :revoked]}
                class="rounded-xl border border-error/30 bg-error/5 p-4 text-sm"
              >
                <div class="font-semibold">Not assignable</div>
                <p class="mt-1 text-xs text-base-content/70">
                  {denied_reason_text(@selected_package)}
                </p>
              </div>

              <div class="rounded-xl border border-base-200 p-4 space-y-2">
                <div class="text-sm font-semibold">Current assignments</div>
                <%= if @assignments == [] do %>
                  <p class="text-xs text-base-content/60">Not assigned to any agent yet.</p>
                <% else %>
                  <ul class="divide-y divide-base-200">
                    <%= for assignment <- @assignments do %>
                      <li class="flex items-center justify-between gap-2 py-2">
                        <div class="text-xs font-mono">{assignment.agent_uid}</div>
                        <div class="flex items-center gap-2">
                          <span class={[
                            "badge badge-sm",
                            if(assignment.enabled, do: "badge-success", else: "badge-ghost")
                          ]}>
                            {if assignment.enabled, do: "enabled", else: "disabled"}
                          </span>
                          <button
                            :if={@can_assign_addons}
                            type="button"
                            class="btn btn-ghost btn-xs"
                            phx-click="delete_assignment"
                            phx-value-id={assignment.id}
                            data-confirm="Remove this add-on assignment?"
                          >
                            Remove
                          </button>
                        </div>
                      </li>
                    <% end %>
                  </ul>
                <% end %>
              </div>

              <div class="rounded-xl border border-base-200 p-4 space-y-3">
                <div class="text-sm font-semibold">Target add-on</div>
                <form
                  id="create-addon-assignment-form"
                  phx-submit="create_assignment"
                  phx-change="assignment_change"
                  class="space-y-3"
                >
                  <div class="grid gap-3 md:grid-cols-2">
                    <div>
                      <label class="label"><span class="label-text">Target</span></label>
                      <select name="assignment[target_mode]" class="select select-bordered w-full">
                        <option value="agent" selected={@assignment_form["target_mode"] == "agent"}>
                          Single agent
                        </option>
                        <option value="cohort" selected={@assignment_form["target_mode"] == "cohort"}>
                          Cohort
                        </option>
                      </select>
                    </div>
                    <div :if={@assignment_form["target_mode"] == "cohort"}>
                      <label class="label"><span class="label-text">Cohort</span></label>
                      <select name="assignment[cohort]" class="select select-bordered w-full">
                        <%= for {label, value} <- @cohort_options do %>
                          <option value={value} selected={@assignment_form["cohort"] == value}>
                            {label}
                          </option>
                        <% end %>
                      </select>
                    </div>
                    <div :if={@assignment_form["target_mode"] != "cohort"} class="md:col-span-2">
                      <label class="label"><span class="label-text">Agent</span></label>
                      <select name="assignment[agent_uid]" class="select select-bordered w-full">
                        <option value="">Select an agent</option>
                        <%= for agent <- @agents do %>
                          <option
                            value={agent.uid}
                            selected={@assignment_form["agent_uid"] == agent.uid}
                          >
                            {agent_label(agent)}
                          </option>
                        <% end %>
                      </select>
                    </div>
                  </div>

                  <div :if={
                    @assignment_form["target_mode"] == "cohort" and
                      @assignment_form["cohort"] == "custom"
                  }>
                    <label class="label"><span class="label-text">Custom Agent IDs</span></label>
                    <textarea
                      name="assignment[agent_ids]"
                      class="textarea textarea-bordered w-full font-mono text-xs min-h-[80px]"
                      placeholder="agent-1, agent-2 or one per line"
                    ><%= @assignment_form["agent_ids"] %></textarea>
                  </div>

                  <div
                    :if={show_assignment_preview?(@assignment_preview)}
                    id="addon-compatibility-preview"
                    class="rounded-lg border border-base-300 bg-base-200/30 px-4 py-3 text-sm"
                  >
                    <div class="flex flex-wrap items-center justify-between gap-3">
                      <div class="font-semibold text-base-content">Compatibility Preview</div>
                      <div class="text-xs text-base-content/60">
                        {assignment_preview_scope_text(@assignment_preview)}
                      </div>
                    </div>

                    <div class="mt-3 flex flex-wrap gap-2">
                      <.ui_badge variant="ghost" size="xs">
                        {@assignment_preview.selected_count} selected
                      </.ui_badge>
                      <.ui_badge variant="success" size="xs">
                        {@assignment_preview.compatible_count} compatible
                      </.ui_badge>
                      <.ui_badge
                        :if={@assignment_preview.unsupported_count > 0}
                        variant="error"
                        size="xs"
                      >
                        {@assignment_preview.unsupported_count} unsupported
                      </.ui_badge>
                      <.ui_badge
                        :if={@assignment_preview.unknown_count > 0}
                        variant="warning"
                        size="xs"
                      >
                        {@assignment_preview.unknown_count} unresolved
                      </.ui_badge>
                    </div>

                    <div
                      :if={assignment_preview_block_message(@assignment_preview)}
                      class="mt-3 text-[11px] font-medium text-warning"
                    >
                      {assignment_preview_block_message(@assignment_preview)}
                    </div>

                    <div :if={@assignment_preview.supported_platforms != []} class="mt-3 space-y-2">
                      <div class="text-[11px] uppercase tracking-wider text-base-content/50">
                        Add-on Supports
                      </div>
                      <div class="flex flex-wrap gap-1">
                        <%= for platform <- @assignment_preview.supported_platforms do %>
                          <.ui_badge variant="ghost" size="xs">{platform}</.ui_badge>
                        <% end %>
                      </div>
                    </div>

                    <div
                      :if={@assignment_preview.unsupported_agents != []}
                      class="mt-3 space-y-2 text-[11px]"
                    >
                      <div class="uppercase tracking-wider text-error">Unsupported Targets</div>
                      <div class="flex flex-wrap gap-1">
                        <%= for agent <- @assignment_preview.unsupported_agents do %>
                          <span class="badge badge-error badge-outline badge-xs">
                            {agent.agent_id} ({agent.platform_label})
                          </span>
                        <% end %>
                      </div>
                    </div>
                  </div>

                  <%= if config_schema_present?(@selected_package.config_schema) do %>
                    <div class="rounded-lg border border-base-200/70 bg-base-100/60 p-3 space-y-3">
                      <div class="text-xs font-semibold text-base-content/70">Configuration</div>
                      <.plugin_config_fields
                        schema={@selected_package.config_schema}
                        params={assignment_params_map(@assignment_form)}
                        base_name="assignment[params]"
                      />
                    </div>

                    <details class="rounded-lg border border-base-200/70 bg-base-100/60 p-3">
                      <summary class="cursor-pointer text-xs font-semibold text-base-content/70">
                        Raw Params (JSON)
                      </summary>
                      <div class="mt-3">
                        <textarea
                          name="assignment[params_raw]"
                          class="textarea textarea-bordered w-full font-mono text-xs min-h-[80px]"
                        ><%= assignment_params_raw(@assignment_form) %></textarea>
                      </div>
                    </details>
                  <% else %>
                    <div>
                      <label class="label"><span class="label-text">Params (JSON)</span></label>
                      <textarea
                        name="assignment[params]"
                        class="textarea textarea-bordered w-full font-mono text-xs min-h-[80px]"
                      ><%= assignment_params_raw(@assignment_form) %></textarea>
                    </div>
                  <% end %>

                  <div>
                    <label class="label"><span class="label-text">Args (one per line)</span></label>
                    <textarea
                      name="assignment[args]"
                      class="textarea textarea-bordered w-full font-mono text-xs min-h-[60px]"
                    ><%= @assignment_form["args"] %></textarea>
                  </div>

                  <div class="flex justify-end">
                    <button
                      type="submit"
                      class="btn btn-primary btn-sm"
                      disabled={
                        @selected_package.status != :approved or not @can_assign_addons or
                          assignment_submit_disabled?(@assignment_form, @assignment_preview)
                      }
                    >
                      Assign
                    </button>
                  </div>
                </form>
                <%= if @selected_package.status != :approved do %>
                  <p class="text-xs text-base-content/60">
                    This add-on must be approved before it can be assigned.
                  </p>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
      </.settings_shell>
    </Layouts.app>
    """
  end

  defp list_addon_packages(scope), do: AddonPackages.list(%{}, scope: scope)

  defp list_assignments_for_package(package_id, scope) do
    AddonAssignments.list(%{addon_package_id: package_id}, scope: scope)
  end

  defp list_agents(scope) do
    Agent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.limit(200)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(scope: scope)
    |> AgentRuntimeMetadata.hydrate_agents()
    |> Enum.filter(&active_agent?/1)
  rescue
    _ -> []
  end

  defp active_agent?(%Agent{status: status, last_seen_time: %DateTime{} = last_seen_time})
       when status in [:connected, :degraded, :connecting] do
    DateTime.diff(DateTime.utc_now(), last_seen_time, :minute) <= 30
  end

  defp active_agent?(%Agent{last_seen_time: %DateTime{} = last_seen_time}) do
    DateTime.diff(DateTime.utc_now(), last_seen_time, :minute) <= 30
  end

  defp active_agent?(_agent), do: false

  defp agent_label(agent) do
    name = agent.name || agent.host || agent.uid
    "#{name} (#{agent.uid})"
  end

  defp default_assignment_form do
    %{
      "target_mode" => "agent",
      "cohort" => "connected",
      "agent_uid" => "",
      "agent_ids" => "",
      "params" => "",
      "params_raw" => "",
      "args" => ""
    }
  end

  defp fetch_agent_uid(form) do
    case String.trim(Map.get(form, "agent_uid") || "") do
      "" -> {:error, :missing_agent}
      uid -> {:ok, uid}
    end
  end

  defp fetch_assignment_agent_uids(%{"target_mode" => "cohort"} = form, package, scope) do
    preview = build_assignment_preview(form, package, scope)

    case preview.compatible_agent_ids do
      [] -> {:error, :empty_cohort}
      agent_uids -> {:ok, agent_uids}
    end
  end

  defp fetch_assignment_agent_uids(form, _package, _scope) do
    with {:ok, agent_uid} <- fetch_agent_uid(form), do: {:ok, [agent_uid]}
  end

  defp create_assignments(agent_uids, package, params, args, scope) do
    Enum.reduce_while(agent_uids, {:ok, 0}, fn agent_uid, {:ok, count} ->
      attrs = %{
        agent_uid: agent_uid,
        addon_package_id: package.id,
        params: params,
        args: args
      }

      # Upsert by (agent_uid, addon_id): re-pushing the same add-on (or upgrading
      # to a newer package of it) must update the existing assignment rather than
      # collide with the one-enabled-per-(agent, add-on) invariant.
      case AddonAssignments.upsert(package.addon_id, attrs, scope: scope) do
        {:ok, _assignment} -> {:cont, {:ok, count + 1}}
        {:error, error} -> {:halt, {:error, error, count}}
      end
    end)
  end

  defp assignment_success_message(1), do: "Add-on assigned to agent."
  defp assignment_success_message(count), do: "Add-on assigned to #{count} agents."

  defp parse_params(form, config_schema) do
    if config_schema_present?(config_schema) do
      structured = Map.get(form, "params")
      raw = Map.get(form, "params_raw")

      cond do
        is_map(structured) and map_size(structured) > 0 -> {:ok, structured}
        is_binary(raw) and String.trim(raw) != "" -> parse_json_object(raw)
        true -> {:ok, %{}}
      end
    else
      raw = Map.get(form, "params")

      if is_binary(raw) and String.trim(raw) != "" do
        parse_json_object(raw)
      else
        {:ok, %{}}
      end
    end
  end

  defp parse_json_object(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, {:invalid_params, "expected a JSON object"}}
      {:error, _error} -> {:error, {:invalid_params, "invalid JSON"}}
    end
  end

  defp parse_args(nil), do: []

  defp parse_args(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_args(_text), do: []

  defp parse_selected_capabilities(form) when is_map(form) do
    form
    |> Map.get("approved_capabilities", [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_selected_capabilities(_form), do: []

  defp assignment_params_map(form) do
    case Map.get(form, "params") do
      %{} = map -> map
      _ -> %{}
    end
  end

  defp assignment_params_raw(form) do
    Map.get(form, "params_raw") || raw_string(Map.get(form, "params")) || ""
  end

  defp raw_string(value) when is_binary(value), do: value
  defp raw_string(_value), do: nil

  defp config_schema_present?(schema) when is_map(schema) do
    properties = Map.get(schema, "properties") || Map.get(schema, :properties) || %{}
    is_map(properties) and map_size(properties) > 0
  end

  defp config_schema_present?(_schema), do: false

  defp empty_assignment_preview do
    %{
      cohort: "agent",
      selected_count: 0,
      compatible_count: 0,
      compatible_agent_ids: [],
      unsupported_count: 0,
      unsupported_agent_ids: [],
      unknown_count: 0,
      supported_platforms: [],
      unsupported_agents: [],
      unknown_agent_ids: []
    }
  end

  defp build_assignment_preview(_form, nil, _scope), do: empty_assignment_preview()

  defp build_assignment_preview(form, package, scope) do
    {selected_agents, unknown_agent_ids, selected_count, cohort} =
      assignment_preview_targets(form, scope)

    {compatible_agents, unsupported_agents} =
      Enum.split_with(selected_agents, &addon_supports_agent?(package, &1))

    unsupported = summarize_unsupported_agents(unsupported_agents)

    %{
      cohort: cohort,
      selected_count: selected_count,
      compatible_count: length(compatible_agents),
      compatible_agent_ids: Enum.map(compatible_agents, & &1.uid),
      unsupported_count: length(unsupported),
      unsupported_agent_ids: Enum.map(unsupported, & &1.agent_id),
      unknown_count: length(unknown_agent_ids),
      supported_platforms: addon_supported_platforms(package),
      unsupported_agents: Enum.take(unsupported, 8),
      unknown_agent_ids: Enum.take(unknown_agent_ids, 8)
    }
  end

  defp assignment_preview_targets(%{"target_mode" => "cohort", "cohort" => "custom"} = form, scope) do
    agent_ids = parse_agent_ids(Map.get(form, "agent_ids"))
    agents = list_agents_by_uid(agent_ids, scope)
    agents_by_uid = Map.new(agents, &{&1.uid, &1})

    selected_agents =
      agent_ids
      |> Enum.map(&Map.get(agents_by_uid, &1))
      |> Enum.reject(&is_nil/1)

    unknown_agent_ids = Enum.reject(agent_ids, &Map.has_key?(agents_by_uid, &1))

    {selected_agents, unknown_agent_ids, length(selected_agents) + length(unknown_agent_ids), "custom"}
  end

  defp assignment_preview_targets(%{"target_mode" => "cohort"}, scope) do
    agents = list_agents(scope)
    {agents, [], length(agents), "connected"}
  end

  defp assignment_preview_targets(form, scope) do
    case fetch_agent_uid(form) do
      {:ok, agent_uid} ->
        agents = list_agents_by_uid([agent_uid], scope)
        {agents, if(agents == [], do: [agent_uid], else: []), 1, "agent"}

      {:error, :missing_agent} ->
        {[], [], 0, "agent"}
    end
  end

  defp list_agents_by_uid([], _scope), do: []

  defp list_agents_by_uid(agent_ids, scope) do
    Agent
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(uid in ^agent_ids)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, agents} -> AgentRuntimeMetadata.hydrate_agents(agents)
      {:error, _error} -> []
    end
  end

  defp parse_agent_ids(value) when is_binary(value) do
    value
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.uniq()
  end

  defp parse_agent_ids(_value), do: []

  defp addon_supports_agent?(package, %Agent{metadata: metadata}) when is_map(metadata) do
    agent_os = metadata_field(metadata, [:os, "os"])
    agent_arch = metadata_field(metadata, [:arch, "arch"])

    platform_allowed_by_requires?(package.requires, agent_os) and
      platform_allowed_by_artifacts?(package.artifacts, agent_os, agent_arch)
  end

  defp addon_supports_agent?(_package, _agent), do: false

  defp platform_allowed_by_requires?(requires, agent_os) when is_map(requires) do
    platforms = Map.get(requires, "platforms") || Map.get(requires, :platforms) || []
    platforms = Enum.map(List.wrap(platforms), &to_string/1)

    platforms == [] or (is_binary(agent_os) and agent_os in platforms)
  end

  defp platform_allowed_by_requires?(_requires, _agent_os), do: true

  defp platform_allowed_by_artifacts?(artifacts, _agent_os, _agent_arch) when artifacts in [nil, %{}], do: true

  defp platform_allowed_by_artifacts?(artifacts, agent_os, agent_arch) when is_map(artifacts) do
    key = platform_label(agent_os, agent_arch)
    is_binary(key) and Map.has_key?(artifacts, key)
  end

  defp platform_allowed_by_artifacts?(_artifacts, _agent_os, _agent_arch), do: true

  defp summarize_unsupported_agents(agents) do
    Enum.map(agents, fn agent ->
      %{
        agent_id: agent.uid,
        platform_label: agent_platform_label(agent) || "unknown platform"
      }
    end)
  end

  defp show_assignment_preview?(preview) do
    preview.selected_count > 0 or preview.supported_platforms != [] or preview.unknown_agent_ids != []
  end

  defp assignment_submit_disabled?(%{"target_mode" => "cohort"}, preview) do
    preview.compatible_count == 0 or preview.unknown_count > 0
  end

  defp assignment_submit_disabled?(_form, _preview), do: false

  defp assignment_preview_scope_text(%{cohort: "custom"}), do: "Current custom cohort"
  defp assignment_preview_scope_text(%{cohort: "connected"}), do: "Current connected cohort"
  defp assignment_preview_scope_text(_preview), do: "Selected agent"

  defp assignment_preview_block_message(preview) do
    cond do
      preview.selected_count == 0 ->
        "Select at least one agent to preview compatibility."

      preview.unknown_count > 0 ->
        "Assignment is blocked until unresolved agent IDs are corrected or removed."

      preview.compatible_count == 0 ->
        "Assignment is blocked until the target includes at least one supported agent."

      preview.unsupported_count > 0 ->
        "Unsupported agents will be skipped; the add-on will target the compatible subset."

      true ->
        nil
    end
  end

  defp addon_supported_platforms(package) do
    package.artifacts
    |> case do
      artifacts when is_map(artifacts) -> Map.keys(artifacts)
      _ -> []
    end
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.sort()
  end

  defp agent_platform_label(%Agent{metadata: metadata}) when is_map(metadata) do
    platform_label(metadata_field(metadata, [:os, "os"]), metadata_field(metadata, [:arch, "arch"]))
  end

  defp agent_platform_label(_agent), do: nil

  defp metadata_field(metadata, keys) when is_map(metadata) do
    Enum.find_value(List.wrap(keys), fn key ->
      case Map.get(metadata, key) do
        nil -> nil
        value -> value
      end
    end)
  end

  defp platform_label(os, arch) do
    case {present_text(os), present_text(arch)} do
      {nil, nil} -> nil
      {os, nil} -> os
      {nil, arch} -> arch
      {os, arch} -> "#{os}/#{arch}"
    end
  end

  defp package_capabilities(nil), do: []

  defp package_capabilities(package) do
    package.capabilities
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp approved_capabilities_text(package) do
    case package.approved_capabilities || [] do
      [] -> "—"
      capabilities -> Enum.join(capabilities, ", ")
    end
  end

  defp denied_reason_text(%{denied_reason: reason}) when is_binary(reason) and reason != "", do: reason

  defp denied_reason_text(_package), do: "Denied or revoked packages are not eligible for delivery."

  defp package_status_badge(:approved), do: "badge-success"
  defp package_status_badge("approved"), do: "badge-success"
  defp package_status_badge(:staged), do: "badge-warning"
  defp package_status_badge("staged"), do: "badge-warning"
  defp package_status_badge(status) when status in [:denied, :revoked, "denied", "revoked"], do: "badge-error"
  defp package_status_badge(_status), do: "badge-ghost"

  defp approved_by(%{user: %{email: email}}) when is_binary(email), do: email
  defp approved_by(_scope), do: nil

  defp current_path_from_url(url), do: URI.parse(url).path

  defp addons_base_path_from_url(url) do
    path = URI.parse(url).path || ""

    if String.starts_with?(path, "/admin/addons") do
      "/admin/addons"
    else
      "/settings/agents/addons"
    end
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error) when is_atom(error), do: Atom.to_string(error)
  defp format_error(%Ash.Error.Invalid{} = error), do: Exception.message(error)
  defp format_error(error), do: inspect(error)

  defp present_text(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_text(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp present_text(_value), do: nil
end
