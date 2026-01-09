defmodule ServiceRadarWebNGWeb.Admin.IntegrationLive.Index do
  @moduledoc """
  LiveView for managing integration sources (Armis, SNMP, etc.).

  Integration sources are stored in Postgres and delivered to sync services
  via gateway-config updates.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.AdminComponents

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Integrations
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Partition

  @impl true
  def mount(_params, _session, socket) do
    tenant_id = get_tenant_id(socket)
    partitions = list_partitions(tenant_id)
    agents = list_agents(tenant_id)
    agent_index = build_agent_index(agents)
    agent_options = build_agent_options(agents)
    sync_agent_available = sync_agent_available?(tenant_id)

    socket =
      socket
      |> assign(:page_title, "Integration Sources")
      |> assign(:sources, list_sources(tenant_id))
      |> assign(:partitions, partitions)
      |> assign(:partition_options, build_partition_options(partitions))
      |> assign(:agents, agents)
      |> assign(:agent_index, agent_index)
      |> assign(:agent_options, agent_options)
      |> assign(:sync_agent_available, sync_agent_available)
      |> assign(:show_create_modal, false)
      |> assign(:show_edit_modal, false)
      |> assign(:show_details_modal, false)
      |> assign(:selected_source, nil)
      |> assign(:create_form, build_create_form(tenant_id, get_actor(socket)))
      |> assign(:edit_form, nil)
      |> assign(:filter_type, nil)
      |> assign(:filter_enabled, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params), do: socket

  defp apply_action(socket, :new, _params) do
    tenant_id = get_tenant_id(socket)

    if sync_agent_available?(tenant_id) do
      assign(socket, :show_create_modal, true)
    else
      socket
      |> put_flash(:error, "Install and register an agent before adding integrations.")
      |> push_navigate(to: ~p"/admin/integrations")
    end
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    tenant_id = get_tenant_id(socket)

    case get_source(id, tenant_id) do
      {:ok, source} ->
        socket
        |> assign(:selected_source, source)
        |> assign(:show_details_modal, true)

      {:error, _} ->
        socket
        |> put_flash(:error, "Integration source not found")
        |> push_navigate(to: ~p"/admin/integrations")
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    tenant_id = get_tenant_id(socket)

    case get_source(id, tenant_id) do
      {:ok, source} ->
        socket
        |> assign(:selected_source, source)
        |> assign(:edit_form, build_edit_form(source, get_actor(socket)))
        |> assign(:show_edit_modal, true)

      {:error, _} ->
        socket
        |> put_flash(:error, "Integration source not found")
        |> push_navigate(to: ~p"/admin/integrations")
    end
  end

  @impl true
  def handle_event("open_create_modal", _params, socket) do
    tenant_id = get_tenant_id(socket)

    if sync_agent_available?(tenant_id) do
      agents = list_agents(tenant_id)
      agent_index = build_agent_index(agents)
      agent_options = build_agent_options(agents)

      {:noreply,
       socket
       |> assign(:show_create_modal, true)
       |> assign(:create_form, build_create_form(tenant_id, get_actor(socket)))
       |> assign(:agents, agents)
       |> assign(:agent_index, agent_index)
       |> assign(:agent_options, agent_options)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "Install and register an agent before adding integrations.")}
    end
  end

  def handle_event("close_create_modal", _params, socket) do
    tenant_id = get_tenant_id(socket)

    {:noreply,
     socket
     |> assign(:show_create_modal, false)
     |> assign(:create_form, build_create_form(tenant_id, get_actor(socket)))}
  end

  def handle_event("close_edit_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_edit_modal, false)
     |> assign(:selected_source, nil)
     |> assign(:edit_form, nil)}
  end

  def handle_event("close_details_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_details_modal, false)
     |> assign(:selected_source, nil)}
  end

  def handle_event("validate_create", %{"form" => params}, socket) do
    form =
      socket.assigns.create_form.source
      |> AshPhoenix.Form.validate(params)
      |> to_form()

    {:noreply, assign(socket, :create_form, form)}
  end

  def handle_event("validate_edit", %{"form" => params}, socket) do
    form =
      socket.assigns.edit_form.source
      |> AshPhoenix.Form.validate(params)
      |> to_form()

    {:noreply, assign(socket, :edit_form, form)}
  end

  def handle_event("create_source", %{"form" => params}, socket) do
    tenant_id = get_tenant_id(socket)
    actor = get_actor(socket)

    if sync_agent_available?(tenant_id) do
      # Add tenant_id to params
      params = Map.put(params, "tenant_id", tenant_id)

      # Handle credentials JSON if provided
      params = parse_credentials_json(params)

      form =
        socket.assigns.create_form.source
        |> AshPhoenix.Form.validate(params)

      case AshPhoenix.Form.submit(form, params: params, actor: actor) do
        {:ok, _source} ->
          {:noreply,
           socket
           |> assign(:show_create_modal, false)
           |> assign(:sources, list_sources(tenant_id))
           |> assign(:create_form, build_create_form(tenant_id, actor))
           |> put_flash(:info, "Integration source created successfully")}

        {:error, form} ->
          {:noreply,
           socket
           |> assign(:create_form, to_form(form))
           |> put_flash(:error, "Failed to create integration source")}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Install and register an agent before adding integrations.")}
    end
  end

  def handle_event("update_source", %{"form" => params}, socket) do
    tenant_id = get_tenant_id(socket)
    actor = get_actor(socket)

    # Handle credentials JSON if provided
    params = parse_credentials_json(params)

    form =
      socket.assigns.edit_form.source
      |> AshPhoenix.Form.validate(params)

    case AshPhoenix.Form.submit(form, params: params, actor: actor) do
      {:ok, _source} ->
        {:noreply,
         socket
         |> assign(:show_edit_modal, false)
         |> assign(:selected_source, nil)
         |> assign(:edit_form, nil)
         |> assign(:sources, list_sources(tenant_id))
         |> put_flash(:info, "Integration source updated successfully")}

      {:error, form} ->
        {:noreply,
         socket
         |> assign(:edit_form, to_form(form))
         |> put_flash(:error, "Failed to update integration source")}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    tenant_id = get_tenant_id(socket)
    actor = get_actor(socket)

    case get_source(id, tenant_id) do
      {:ok, source} ->
        action = if source.enabled, do: :disable, else: :enable

        case Ash.update(source, action, actor: actor) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:sources, list_sources(tenant_id))
             |> put_flash(:info, "Integration source #{action}d")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to toggle integration source")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Integration source not found")}
    end
  end

  def handle_event("delete_source", %{"id" => id}, socket) do
    tenant_id = get_tenant_id(socket)
    actor = get_actor(socket)

    case get_source(id, tenant_id) do
      {:ok, source} ->
        case Ash.destroy(source, actor: actor) do
          :ok ->
            {:noreply,
             socket
             |> assign(:show_details_modal, false)
             |> assign(:selected_source, nil)
             |> assign(:sources, list_sources(tenant_id))
             |> put_flash(:info, "Integration source deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete integration source")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Integration source not found")}
    end
  end

  def handle_event("filter", params, socket) do
    tenant_id = get_tenant_id(socket)

    source_type = Map.get(params, "source_type", "")
    enabled = Map.get(params, "enabled", "")

    filters = %{}
    filters = if source_type != "", do: Map.put(filters, :source_type, source_type), else: filters
    filters = if enabled != "", do: Map.put(filters, :enabled, enabled == "true"), else: filters

    {:noreply,
     socket
     |> assign(:filter_type, if(source_type == "", do: nil, else: source_type))
     |> assign(:filter_enabled, if(enabled == "", do: nil, else: enabled == "true"))
     |> assign(:sources, list_sources(tenant_id, filters))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-6xl p-6 space-y-6">
        <.admin_nav current_path="/admin/integrations" />

        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">Integration Sources</h1>
            <p class="text-sm text-base-content/60">
              Manage data source integrations (Armis, SNMP, Syslog, etc.)
            </p>
          </div>
          <div class="flex flex-col items-end gap-2">
            <.ui_button
              variant="primary"
              size="sm"
              phx-click="open_create_modal"
              disabled={not @sync_agent_available}
            >
              <.icon name="hero-plus" class="size-4" /> New Source
            </.ui_button>
            <.ui_button
              variant="outline"
              size="sm"
              navigate={~p"/admin/edge-packages/new?component_type=agent"}
            >
              <.icon name="hero-link" class="size-4" /> Add Edge Agent
            </.ui_button>
            <%= if not @sync_agent_available do %>
              <p class="text-xs text-base-content/60">
                Register an agent before adding integrations.
              </p>
            <% end %>
          </div>
        </div>

        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">Sources</div>
              <p class="text-xs text-base-content/60">
                {@sources |> length()} source(s)
              </p>
            </div>
            <div class="flex gap-2">
              <select
                name="source_type"
                class="select select-sm select-bordered"
                phx-change="filter"
              >
                <option value="">All Types</option>
                <option value="armis" selected={@filter_type == "armis"}>Armis</option>
                <option value="snmp" selected={@filter_type == "snmp"}>SNMP</option>
                <option value="syslog" selected={@filter_type == "syslog"}>Syslog</option>
                <option value="nmap" selected={@filter_type == "nmap"}>Nmap</option>
                <option value="custom" selected={@filter_type == "custom"}>Custom</option>
              </select>
              <select
                name="enabled"
                class="select select-sm select-bordered"
                phx-change="filter"
              >
                <option value="">All Status</option>
                <option value="true" selected={@filter_enabled == true}>Enabled</option>
                <option value="false" selected={@filter_enabled == false}>Disabled</option>
              </select>
            </div>
          </:header>

          <div class="overflow-x-auto">
            <%= if @sources == [] do %>
              <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-8 text-center">
                <div class="text-sm font-semibold text-base-content">No integration sources</div>
                <p class="mt-1 text-xs text-base-content/60">
                  Create a new integration source to connect to external data sources.
                </p>
              </div>
            <% else %>
              <table class="table table-sm">
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-base-content/60">
                    <th>Name</th>
                    <th>Type</th>
                    <th>Partition</th>
                    <th>Agent</th>
                    <th>Endpoint</th>
                    <th>Status</th>
                    <th>Last Sync</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for source <- @sources do %>
                    <tr class="hover:bg-base-200/30">
                      <td>
                        <div class="font-medium">{source.name}</div>
                        <div class="text-xs text-base-content/60 font-mono">
                          {String.slice(source.id, 0, 8)}...
                        </div>
                      </td>
                      <td>
                        <.source_type_badge type={source.source_type} />
                      </td>
                      <td class="text-xs text-base-content/70">
                        {source.partition || "-"}
                      </td>
                      <td class="text-xs text-base-content/70">
                        <%= if source.agent_id && source.agent_id != "" do %>
                          <% agent = Map.get(@agent_index, source.agent_id) %>
                          <div class="font-medium">
                            {agent_display_name(agent, source.agent_id)}
                          </div>
                          <div class="mt-1">
                            <%= if agent do %>
                              <.agent_status_badge agent={agent} />
                            <% else %>
                              <.ui_badge variant="ghost" size="xs">Unknown</.ui_badge>
                            <% end %>
                          </div>
                        <% else %>
                          <span class="text-xs text-base-content/60">Auto-assign</span>
                        <% end %>
                      </td>
                      <td class="text-xs text-base-content/70 max-w-[200px] truncate">
                        {source.endpoint}
                      </td>
                      <td>
                        <.status_badge enabled={source.enabled} result={source.last_sync_result} />
                      </td>
                      <td class="text-xs text-base-content/70">
                        {format_datetime(source.last_sync_at)}
                      </td>
                      <td>
                        <div class="flex gap-1">
                          <.ui_button
                            variant="ghost"
                            size="xs"
                            navigate={~p"/admin/integrations/#{source.id}"}
                          >
                            View
                          </.ui_button>
                          <.ui_button
                            variant="ghost"
                            size="xs"
                            navigate={~p"/admin/integrations/#{source.id}/edit"}
                          >
                            Edit
                          </.ui_button>
                          <.ui_button
                            variant="ghost"
                            size="xs"
                            phx-click="toggle_enabled"
                            phx-value-id={source.id}
                          >
                            {if source.enabled, do: "Disable", else: "Enable"}
                          </.ui_button>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            <% end %>
          </div>
        </.ui_panel>
      </div>

      <.create_modal
        :if={@show_create_modal}
        form={@create_form}
        partition_options={@partition_options}
        agent_options={@agent_options}
      />
      <.edit_modal
        :if={@show_edit_modal}
        form={@edit_form}
        source={@selected_source}
        partition_options={@partition_options}
        agent_options={@agent_options}
      />
      <.details_modal
        :if={@show_details_modal}
        source={@selected_source}
        agent_index={@agent_index}
      />
    </Layouts.app>
    """
  end

  defp create_modal(assigns) do
    ~H"""
    <dialog id="create_modal" class="modal modal-open">
      <div class="modal-box max-w-lg">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_create_modal"
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-bold">Create Integration Source</h3>
        <p class="py-2 text-sm text-base-content/70">
          Configure a new data source integration.
        </p>

        <.form
          for={@form}
          id="create_source_form"
          phx-change="validate_create"
          phx-submit="create_source"
          class="space-y-4 mt-4"
        >
          <.input
            field={@form[:name]}
            type="text"
            label="Name"
            placeholder="e.g., Production Armis"
            required
          />

          <.input
            field={@form[:source_type]}
            type="select"
            label="Source Type"
            options={[
              {"Armis", :armis},
              {"SNMP", :snmp},
              {"Syslog", :syslog},
              {"Nmap", :nmap},
              {"Custom", :custom}
            ]}
          />

          <.input
            field={@form[:endpoint]}
            type="text"
            label="Endpoint URL"
            placeholder="https://api.armis.com"
            required
          />

          <.input
            field={@form[:partition]}
            type="select"
            label="Partition"
            options={@partition_options}
            prompt="Select a partition..."
          />

          <.input
            field={@form[:agent_id]}
            type="select"
            label="Agent"
            options={@agent_options}
            prompt="Auto-assign to any connected agent"
          />

          <.input
            field={@form[:gateway_id]}
            type="text"
            label="Gateway ID (Optional)"
            placeholder="Gateway to assign this source to"
          />

          <.input
            field={@form[:poll_interval_seconds]}
            type="number"
            label="Poll Interval (seconds)"
            placeholder="300"
          />

          <div class="form-control">
            <label class="label">
              <span class="label-text">Credentials (JSON)</span>
            </label>
            <textarea
              name="credentials_json"
              class="textarea textarea-bordered w-full font-mono text-sm"
              rows="4"
              placeholder='{"api_key": "your-api-key", "api_secret": "your-secret"}'
            ></textarea>
            <label class="label">
              <span class="label-text-alt text-base-content/60">
                Credentials will be encrypted at rest
              </span>
            </label>
          </div>

          <div class="modal-action">
            <button type="button" class="btn" phx-click="close_create_modal">Cancel</button>
            <button type="submit" class="btn btn-primary">Create Source</button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_create_modal">close</button>
      </form>
    </dialog>
    """
  end

  defp edit_modal(assigns) do
    ~H"""
    <dialog id="edit_modal" class="modal modal-open">
      <div class="modal-box max-w-lg">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_edit_modal"
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-bold">Edit Integration Source</h3>
        <p class="py-2 text-sm text-base-content/70">
          Update the integration source configuration.
        </p>

        <.form
          for={@form}
          id="edit_source_form"
          phx-change="validate_edit"
          phx-submit="update_source"
          class="space-y-4 mt-4"
        >
          <.input field={@form[:name]} type="text" label="Name" required />

          <.input
            field={@form[:endpoint]}
            type="text"
            label="Endpoint URL"
            required
          />

          <.input
            field={@form[:partition]}
            type="select"
            label="Partition"
            options={@partition_options}
            prompt="Select a partition..."
          />

          <.input
            field={@form[:agent_id]}
            type="select"
            label="Agent"
            options={@agent_options}
            prompt="Auto-assign to any connected agent"
          />
          <.input field={@form[:gateway_id]} type="text" label="Gateway ID (Optional)" />

          <.input
            field={@form[:poll_interval_seconds]}
            type="number"
            label="Poll Interval (seconds)"
          />

          <div class="form-control">
            <label class="label">
              <span class="label-text">New Credentials (JSON, leave empty to keep existing)</span>
            </label>
            <textarea
              name="credentials_json"
              class="textarea textarea-bordered w-full font-mono text-sm"
              rows="4"
              placeholder='{"api_key": "your-api-key", "api_secret": "your-secret"}'
            ></textarea>
          </div>

          <div class="modal-action">
            <button type="button" class="btn" phx-click="close_edit_modal">Cancel</button>
            <button type="submit" class="btn btn-primary">Update Source</button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_edit_modal">close</button>
      </form>
    </dialog>
    """
  end

  defp details_modal(assigns) do
    ~H"""
    <dialog id="details_modal" class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_details_modal"
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-bold">Integration Source Details</h3>

        <div class="mt-4 space-y-4">
          <div class="grid grid-cols-2 gap-4">
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Name</div>
              <div class="font-medium">{@source.name}</div>
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Status</div>
              <.status_badge enabled={@source.enabled} result={@source.last_sync_result} />
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Type</div>
              <.source_type_badge type={@source.source_type} />
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Poll Interval</div>
              <div>{format_interval(@source.poll_interval_seconds)}</div>
            </div>
          </div>

          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Endpoint</div>
            <code class="text-sm font-mono bg-base-200 p-2 rounded block">{@source.endpoint}</code>
          </div>

          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Source ID</div>
            <code class="text-sm font-mono bg-base-200 p-2 rounded block">{@source.id}</code>
          </div>

          <%= if @source.partition do %>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Partition</div>
              <code class="text-sm font-mono bg-base-200 p-2 rounded block">{@source.partition}</code>
            </div>
          <% end %>

          <%= if @source.agent_id && @source.agent_id != "" do %>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Agent ID</div>
              <% agent = Map.get(@agent_index, @source.agent_id) %>
              <div class="flex flex-col gap-2">
                <code class="text-sm font-mono bg-base-200 p-2 rounded block">
                  {@source.agent_id}
                </code>
                <%= if agent do %>
                  <.agent_status_badge agent={agent} />
                <% else %>
                  <.ui_badge variant="ghost" size="xs">Unknown</.ui_badge>
                <% end %>
              </div>
            </div>
          <% end %>

          <%= if @source.gateway_id do %>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Gateway ID</div>
              <code class="text-sm font-mono bg-base-200 p-2 rounded block">
                {@source.gateway_id}
              </code>
            </div>
          <% end %>

          <div class="divider">Sync Statistics</div>

          <div class="grid grid-cols-3 gap-4">
            <div class="stat bg-base-200 rounded-lg p-3">
              <div class="stat-title text-xs">Total Syncs</div>
              <div class="stat-value text-lg">{@source.total_syncs || 0}</div>
            </div>
            <div class="stat bg-base-200 rounded-lg p-3">
              <div class="stat-title text-xs">Last Device Count</div>
              <div class="stat-value text-lg">{@source.last_device_count || 0}</div>
            </div>
            <div class="stat bg-base-200 rounded-lg p-3">
              <div class="stat-title text-xs">Consecutive Failures</div>
              <div class="stat-value text-lg">{@source.consecutive_failures || 0}</div>
            </div>
          </div>

          <%= if @source.last_sync_at do %>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Last Sync</div>
              <div class="text-sm">{format_datetime(@source.last_sync_at)}</div>
            </div>
          <% end %>

          <%= if @source.last_error_message do %>
            <div class="alert alert-error text-sm">
              <.icon name="hero-exclamation-circle" class="size-5" />
              <span>{@source.last_error_message}</span>
            </div>
          <% end %>
        </div>

        <div class="modal-action">
          <button
            type="button"
            class="btn btn-error btn-outline"
            phx-click="delete_source"
            phx-value-id={@source.id}
            data-confirm="Are you sure you want to delete this integration source? This cannot be undone."
          >
            Delete
          </button>
          <.ui_button variant="ghost" navigate={~p"/admin/integrations/#{@source.id}/edit"}>
            Edit
          </.ui_button>
          <button type="button" class="btn" phx-click="close_details_modal">Close</button>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_details_modal">close</button>
      </form>
    </dialog>
    """
  end

  defp source_type_badge(assigns) do
    variant =
      case assigns.type do
        :armis -> "info"
        :snmp -> "success"
        :syslog -> "warning"
        :nmap -> "error"
        :custom -> "ghost"
        _ -> "ghost"
      end

    assigns = assign(assigns, :variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@type}</.ui_badge>
    """
  end

  defp status_badge(assigns) do
    {variant, label} =
      cond do
        not assigns.enabled -> {"ghost", "Disabled"}
        assigns.result == :success -> {"success", "Healthy"}
        assigns.result == :partial -> {"warning", "Partial"}
        assigns.result in [:failed, :timeout] -> {"error", "Failed"}
        is_nil(assigns.result) -> {"info", "Never Run"}
        true -> {"ghost", "Unknown"}
      end

    assigns = assigns |> assign(:variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_interval(nil), do: "5 minutes"

  defp format_interval(seconds) when is_integer(seconds) do
    cond do
      seconds >= 3600 -> "#{div(seconds, 3600)} hour(s)"
      seconds >= 60 -> "#{div(seconds, 60)} minute(s)"
      true -> "#{seconds} second(s)"
    end
  end

  # Data access helpers

  defp list_partitions(tenant_id) do
    schema = tenant_schema(tenant_id)

    Partition
    |> Ash.Query.for_read(:enabled)
    |> Ash.read!(tenant: schema, authorize?: false)
  rescue
    _ -> []
  end

  defp build_partition_options(partitions) do
    # Always include a "default" option for agents that haven't been assigned
    default_option = [{"Default", "default"}]

    partition_options =
      partitions
      |> Enum.map(fn p -> {p.name || p.slug, p.slug} end)
      |> Enum.sort_by(&elem(&1, 0))

    default_option ++ partition_options
  end

  defp list_agents(tenant_id) do
    schema = tenant_schema(tenant_id)

    Agent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort([:name, :uid])
    |> Ash.read(tenant: schema, authorize?: false)
    |> case do
      {:ok, %Ash.Page.Keyset{results: results}} -> results
      {:ok, results} when is_list(results) -> results
      _ -> []
    end
  rescue
    _ -> []
  end

  defp build_agent_options(agents) do
    agents
    |> Enum.map(fn agent ->
      label = "#{agent_display_name(agent, agent.uid)} - #{agent_status_label(agent)}"
      {label, agent.uid}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp build_agent_index(agents) do
    Map.new(agents, fn agent -> {agent.uid, agent} end)
  end

  defp list_sources(tenant_id, filters \\ %{}) do
    schema = tenant_schema(tenant_id)
    opts = [tenant: schema, authorize?: false]

    case Map.get(filters, :source_type) do
      nil ->
        IntegrationSource
        |> Ash.Query.for_read(:read)
        |> maybe_filter_enabled(filters)
        |> Ash.read!(opts)

      type ->
        type_atom = if is_binary(type), do: String.to_existing_atom(type), else: type

        IntegrationSource
        |> Ash.Query.for_read(:by_type, %{source_type: type_atom})
        |> maybe_filter_enabled(filters)
        |> Ash.read!(opts)
    end
  rescue
    _ -> []
  end

  defp sync_agent_available?(tenant_id) do
    schema = tenant_schema(tenant_id)

    Agent
    |> Ash.Query.for_read(:connected)
    |> Ash.Query.limit(1)
    |> Ash.read(tenant: schema, authorize?: false)
    |> case do
      {:ok, %Ash.Page.Keyset{results: results}} -> results != []
      {:ok, results} when is_list(results) -> results != []
      _ -> false
    end
  rescue
    _ -> false
  end

  defp maybe_filter_enabled(query, %{enabled: value}) when is_boolean(value) do
    require Ash.Query
    Ash.Query.filter(query, enabled: value)
  end

  defp maybe_filter_enabled(query, _), do: query

  defp get_source(id, tenant_id) do
    schema = tenant_schema(tenant_id)
    IntegrationSource.get_by_id(id, tenant: schema, authorize?: false)
  end

  defp build_create_form(tenant_id, actor) do
    schema = tenant_schema(tenant_id)

    IntegrationSource
    |> AshPhoenix.Form.for_create(:create,
      domain: Integrations,
      tenant: schema,
      actor: actor,
      transform_params: fn _form, params, _action ->
        # Set tenant_id
        params = Map.put(params, "tenant_id", tenant_id)

        # Convert source_type string to atom
        params =
          case params["source_type"] do
            type when is_binary(type) and type != "" ->
              Map.put(params, "source_type", String.to_existing_atom(type))

            _ ->
              params
          end

        normalize_optional_params(params)
      end
    )
    |> to_form()
  end

  defp build_edit_form(source, actor) do
    source
    |> AshPhoenix.Form.for_update(:update,
      domain: Integrations,
      actor: actor,
      transform_params: fn _form, params, _action ->
        normalize_optional_params(params)
      end
    )
    |> to_form()
  end

  defp normalize_optional_params(params) do
    params
    |> normalize_blank_param("agent_id")
    |> normalize_blank_param("gateway_id")
    |> normalize_blank_param("partition")
  end

  defp normalize_blank_param(params, key) do
    case Map.get(params, key) do
      "" -> Map.put(params, key, nil)
      _ -> params
    end
  end

  defp parse_credentials_json(params) do
    case Map.get(params, "credentials_json") do
      json when is_binary(json) and json != "" ->
        case Jason.decode(json) do
          {:ok, credentials} -> Map.put(params, "credentials", credentials)
          {:error, _} -> params
        end

      _ ->
        params
    end
  end

  defp get_tenant_id(socket) do
    case socket.assigns[:current_scope] do
      %{user: %{tenant_id: tenant_id}} when not is_nil(tenant_id) -> tenant_id
      _ -> default_tenant_id()
    end
  end

  # Convert tenant_id (UUID) to schema name for Ash multitenancy context
  defp tenant_schema(tenant_id) when is_binary(tenant_id) do
    TenantSchemas.schema_for_id(tenant_id)
  end

  defp tenant_schema(_), do: nil

  defp agent_display_name(nil, fallback), do: fallback || "Unknown"
  defp agent_display_name(agent, _fallback), do: agent.name || agent.uid

  defp agent_status_label(agent) do
    cond do
      agent.status == :connected and agent.is_healthy -> "Connected"
      agent.status == :connected -> "Unhealthy"
      agent.status == :degraded -> "Degraded"
      agent.status == :disconnected -> "Disconnected"
      agent.status == :unavailable -> "Unavailable"
      agent.status == :connecting -> "Connecting"
      true -> "Unknown"
    end
  end

  defp agent_status_variant(agent) do
    cond do
      agent.status == :connected and agent.is_healthy -> "success"
      agent.status == :connected -> "warning"
      agent.status == :degraded -> "warning"
      agent.status == :disconnected -> "error"
      agent.status == :unavailable -> "error"
      agent.status == :connecting -> "info"
      true -> "ghost"
    end
  end

  defp agent_status_badge(assigns) do
    variant = agent_status_variant(assigns.agent)
    label = agent_status_label(assigns.agent)
    assigns = assign(assigns, :variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp default_tenant_id do
    case Application.get_env(:serviceradar_web_ng, :env) do
      :test -> "00000000-0000-0000-0000-000000000099"
      _ -> "00000000-0000-0000-0000-000000000000"
    end
  end

  defp get_actor(socket) do
    case socket.assigns[:current_scope] do
      %{user: user} when not is_nil(user) -> user
      _ -> nil
    end
  end
end
