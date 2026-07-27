defmodule ServiceRadarWebNGWeb.Settings.RemoteAccessDesktopTargetsLive do
  @moduledoc """
  Operator settings page for registered RDP hosts.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Edge.RemoteAccessDesktopTarget
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Gateway
  alias ServiceRadar.Inventory.Device
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNG.RemoteAccessDesktopTargets
  alias ServiceRadarWebNGWeb.FeatureFlags
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Ash.Query

  @current_path "/settings/networks/desktop-targets"
  @manage_permission "settings.edge.manage"
  @credential_modes %{
    "user_present" => :user_present,
    "centrally_brokered" => :centrally_brokered
  }
  @credential_mode_options [
    {"Prompt user when connecting", "user_present"},
    {"Use a credential rule", "centrally_brokered"}
  ]
  @target_kinds %{"inventory_device" => :inventory_device}
  @clipboard_modes ~w(disabled local_to_remote remote_to_local bidirectional)
  @recording_modes ~w(metadata_only screen_content)
  @target_tls_modes ~w(verify_ca skip_verify)

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    cond do
      not FeatureFlags.remote_access_desktop_rdp_enabled?() ->
        {:ok,
         socket
         |> put_flash(:error, "RDP remote access is not enabled")
         |> redirect(to: ~p"/settings/profile")}

      not can_manage?(scope) ->
        {:ok,
         socket
         |> put_flash(:error, "Not authorized to manage RDP hosts")
         |> redirect(to: ~p"/settings/profile")}

      true ->
        {:ok,
         socket
         |> assign(:page_title, "RDP Access")
         |> assign(:current_path, @current_path)
         |> assign(:targets, [])
         |> assign(:loading?, true)
         |> assign(:form_mode, nil)
         |> assign(:editing_target, nil)
         |> assign(:device_options, [])
         |> assign(:device_option_data, %{})
         |> assign(:agent_options, [])
         |> assign(:agent_option_data, %{})
         |> assign(:gateway_options, [])
         |> assign(:credential_rule_options, [])
         |> assign(:target_form, target_form(default_target_params()))}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if fresh_can_manage?(socket.assigns.current_scope) do
      socket =
        socket
        |> assign(:current_path, @current_path)
        |> assign(:form_mode, socket.assigns.live_action)

      if connected?(socket) do
        {:noreply, load_page(socket, params)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, unauthorized(socket)}
    end
  end

  @impl true
  def handle_event("change_target", %{"desktop_target" => params}, socket) do
    authorize_manage_event(socket, fn ->
      params =
        params
        |> apply_selected_device(socket.assigns.device_option_data)
        |> apply_selected_agent(socket.assigns.agent_option_data)

      {:noreply, assign(socket, :target_form, target_form(normalize_form_params(params)))}
    end)
  end

  def handle_event("save_target", %{"desktop_target" => params}, socket) do
    authorize_manage_event(socket, fn ->
      case normalize_target_attrs(params) do
        {:ok, attrs} ->
          save_target(socket, attrs)

        {:error, message} ->
          {:noreply,
           socket
           |> assign(:target_form, target_form(normalize_form_params(params)))
           |> put_flash(:error, message)}
      end
    end)
  end

  def handle_event("disable_target", %{"id" => id}, socket) do
    authorize_manage_event(socket, fn ->
      set_enabled(socket, id, false, "RDP host disabled")
    end)
  end

  def handle_event("enable_target", %{"id" => id}, socket) do
    authorize_manage_event(socket, fn ->
      set_enabled(socket, id, true, "RDP host enabled")
    end)
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:credential_mode_options, @credential_mode_options)
      |> assign(:target_tls_mode_options, enum_options(@target_tls_modes))
      |> assign(:clipboard_mode_options, enum_options(@clipboard_modes))
      |> assign(:recording_mode_options, enum_options(@recording_modes))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <section class="space-y-4">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h1 class="text-xl font-semibold">RDP Access</h1>
              <p class="mt-1 text-sm text-sr-muted">
                Make Windows desktops available through trusted edge agents.
              </p>
            </div>
            <.ui_button
              navigate={~p"/settings/networks/desktop-targets/new"}
              size="sm"
              variant="primary"
            >
              Add RDP Host
            </.ui_button>
          </div>

          <div class="overflow-hidden rounded-lg border border-sr-line bg-sr-surface">
            <div class="sr-ui-table-shell">
              <table class={ui_table_class(size: "sm")}>
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Target</th>
                    <th>Route</th>
                    <th>Credential</th>
                    <th>Policy</th>
                    <th>Status</th>
                    <th class="text-right">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :if={@loading?}>
                    <td colspan="7" class="py-8 text-center text-sm text-sr-muted">
                      Loading RDP hosts.
                    </td>
                  </tr>
                  <tr :if={!@loading? and @targets == []}>
                    <td colspan="7" class="py-8 text-center text-sm text-sr-muted">
                      No RDP hosts are configured yet. Open a device and choose Enable RDP, or add
                      one here.
                    </td>
                  </tr>
                  <tr :for={target <- @targets}>
                    <td>
                      <div class="font-medium">{target.name}</div>
                      <div :if={target.description} class="text-xs text-sr-muted">
                        {target.description}
                      </div>
                    </td>
                    <td>
                      <div>{target.target_host}:{target.target_port}</div>
                      <div class="text-xs text-sr-muted">{target.device_uid}</div>
                    </td>
                    <td>
                      <div>{target.agent_id || "-"}</div>
                      <div :if={target.gateway_id} class="text-xs text-sr-muted">
                        {target.gateway_id}
                      </div>
                    </td>
                    <td>
                      <.ui_badge size="sm" variant="ghost">
                        {enum_label(target.credential_custody_mode)}
                      </.ui_badge>
                    </td>
                    <td>
                      <div class="flex flex-wrap gap-1">
                        <.ui_badge size="sm" variant="outline">
                          TLS {policy_value(target.target_tls, "mode", "verify_ca")}
                        </.ui_badge>
                        <.ui_badge size="sm" variant="outline">
                          NLA {if policy_value(target.nla, "required", true),
                            do: "required",
                            else: "optional"}
                        </.ui_badge>
                        <.ui_badge size="sm" variant="outline">
                          Clipboard {policy_value(target.redirection_policy, "clipboard", "disabled")}
                        </.ui_badge>
                      </div>
                    </td>
                    <td>
                      <.ui_badge
                        size="sm"
                        variant={if(target.enabled, do: "success", else: "ghost")}
                      >
                        {if target.enabled, do: "Enabled", else: "Disabled"}
                      </.ui_badge>
                    </td>
                    <td class="text-right">
                      <div class="flex justify-end gap-2">
                        <.ui_button
                          navigate={~p"/settings/networks/desktop-targets/#{target.id}/edit"}
                          size="xs"
                          variant="ghost"
                        >
                          Edit
                        </.ui_button>
                        <.ui_button
                          :if={target.enabled}
                          type="button"
                          phx-click="disable_target"
                          phx-value-id={target.id}
                          size="xs"
                          variant="ghost"
                        >
                          Disable
                        </.ui_button>
                        <.ui_button
                          :if={!target.enabled}
                          type="button"
                          phx-click="enable_target"
                          phx-value-id={target.id}
                          size="xs"
                          variant="ghost"
                        >
                          Enable
                        </.ui_button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </section>

        <.target_form_modal
          :if={@form_mode in [:new, :edit]}
          form={@target_form}
          mode={@form_mode}
          credential_mode_options={@credential_mode_options}
          target_tls_mode_options={@target_tls_mode_options}
          clipboard_mode_options={@clipboard_mode_options}
          recording_mode_options={@recording_mode_options}
          device_options={@device_options}
          agent_options={@agent_options}
          gateway_options={@gateway_options}
          credential_rule_options={@credential_rule_options}
        />
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  attr(:form, :map, required: true)
  attr(:mode, :atom, required: true)
  attr(:credential_mode_options, :list, required: true)
  attr(:target_tls_mode_options, :list, required: true)
  attr(:clipboard_mode_options, :list, required: true)
  attr(:recording_mode_options, :list, required: true)
  attr(:device_options, :list, required: true)
  attr(:agent_options, :list, required: true)
  attr(:gateway_options, :list, required: true)
  attr(:credential_rule_options, :list, required: true)

  defp target_form_modal(assigns) do
    ~H"""
    <dialog
      id="remote-access-desktop-ta-modal-1"
      class="sr-ui-modal sr-ui-modal-open"
      phx-hook="DialogTopLayer"
    >
      <div class="sr-ui-modal-box sr-ui-modal-box-xl rounded-lg">
        <div class="mb-4 flex items-center justify-between">
          <h2 class="text-lg font-semibold">
            {if @mode == :new, do: "Enable RDP Access", else: "Edit RDP Access"}
          </h2>
          <.ui_button navigate={~p"/settings/networks/desktop-targets"} size="sm" variant="ghost">
            Close
          </.ui_button>
        </div>

        <.form for={@form} phx-change="change_target" phx-submit="save_target" class="space-y-5">
          <div class="grid gap-4 md:grid-cols-2">
            <.input field={@form[:name]} label="Name" required />
            <.input
              field={@form[:enabled]}
              type="checkbox"
              label="Enabled"
            />
            <.input field={@form[:description]} type="textarea" label="Description" />
            <.input field={@form[:target_kind]} type="hidden" />
            <%= if @device_options == [] do %>
              <div class="rounded-lg border border-warning/40 bg-warning/10 p-3 text-sm md:col-span-2">
                No inventory devices are available to select. <.link
                  navigate={~p"/devices"}
                  class="text-sr-brand hover:underline"
                >Open device inventory</.link>.
              </div>
            <% else %>
              <.input
                field={@form[:device_uid]}
                type="select"
                label="Device"
                prompt="Select a device"
                options={@device_options}
                required
              />
            <% end %>
            <.input field={@form[:target_host]} label="RDP Hostname or IP" required />
            <.input
              field={@form[:target_port]}
              type="number"
              label="Target Port"
              min="1"
              max="65535"
              required
            />
            <%= if @agent_options == [] do %>
              <div class="rounded-lg border border-warning/40 bg-warning/10 p-3 text-sm">
                No active agents are available. The target can be saved, but sessions need an RDP-capable agent.
              </div>
            <% else %>
              <.input
                field={@form[:agent_id]}
                type="select"
                label="Edge Agent"
                prompt="Auto-route or select an agent"
                options={@agent_options}
              />
            <% end %>
            <%= if @gateway_options == [] do %>
              <div class="rounded-lg border border-warning/40 bg-warning/10 p-3 text-sm">
                No healthy gateways are available. The selected agent can still supply its gateway when known.
              </div>
            <% else %>
              <.input
                field={@form[:gateway_id]}
                type="select"
                label="Gateway"
                prompt="Use agent gateway"
                options={@gateway_options}
              />
            <% end %>
            <.input
              field={@form[:credential_custody_mode]}
              type="select"
              label="RDP Sign-in"
              options={@credential_mode_options}
              required
            />
            <%= if @credential_rule_options == [] do %>
              <div class="rounded-lg border border-info/40 bg-info/10 p-3 text-sm">
                No credential rules exist yet.
                <.link
                  navigate={~p"/settings/networks/credentials/new"}
                  class="text-sr-brand hover:underline"
                >
                  Create a credential rule
                </.link>
                if you want stored/brokered credentials. Users can still connect by entering
                credentials at session start.
              </div>
              <.input field={@form[:credential_rule_id]} type="hidden" />
            <% else %>
              <.input
                field={@form[:credential_rule_id]}
                type="select"
                label="Credential Rule"
                prompt="Prompt user instead"
                options={@credential_rule_options}
              />
            <% end %>
          </div>

          <div class="grid gap-4 lg:grid-cols-3">
            <fieldset class="rounded-lg border border-sr-line p-4">
              <legend class="px-1 text-sm font-medium">RDP Security</legend>
              <div class="space-y-3">
                <.input
                  field={@form[:target_tls_mode]}
                  type="select"
                  label="Target TLS"
                  options={@target_tls_mode_options}
                  required
                />
                <.input field={@form[:target_tls_server_name]} label="TLS Server Name" />
                <.input field={@form[:target_tls_ca_bundle_id]} type="hidden" />
                <.input
                  field={@form[:target_tls_ca_bundle_pem]}
                  type="textarea"
                  label="CA Certificate"
                  placeholder="Paste the issuing CA PEM when Target TLS is Verify CA"
                />
                <.input field={@form[:nla_required]} type="checkbox" label="Require NLA" />
                <.input
                  field={@form[:recording_mode]}
                  type="select"
                  label="Recording"
                  options={@recording_mode_options}
                  required
                />
              </div>
            </fieldset>

            <fieldset class="rounded-lg border border-sr-line p-4">
              <legend class="px-1 text-sm font-medium">Kerberos Routing</legend>
              <div class="space-y-3">
                <.input field={@form[:kdc_proxy_url]} label="KDC Proxy URL" />
                <.input field={@form[:kerberos_hostname]} label="Kerberos Hostname" />
              </div>
            </fieldset>

            <fieldset class="rounded-lg border border-sr-line p-4">
              <legend class="px-1 text-sm font-medium">Screen Policy</legend>
              <div class="grid gap-3 sm:grid-cols-2">
                <.input field={@form[:max_width]} type="number" label="Max Width" min="1" />
                <.input field={@form[:max_height]} type="number" label="Max Height" min="1" />
                <.input field={@form[:frame_rate]} type="number" label="FPS" min="1" />
                <.input field={@form[:bitrate_kbps]} type="number" label="Kbps" min="1" />
              </div>
            </fieldset>

            <fieldset class="rounded-lg border border-sr-line p-4">
              <legend class="px-1 text-sm font-medium">Redirection</legend>
              <.input
                field={@form[:clipboard]}
                type="select"
                label="Clipboard"
                options={@clipboard_mode_options}
                required
              />
            </fieldset>
          </div>

          <.input
            field={@form[:allowed_principals]}
            type="textarea"
            label="Allowed Principals"
          />

          <div class="sr-ui-modal-action">
            <.ui_button navigate={~p"/settings/networks/desktop-targets"} size="sm" variant="ghost">
              Cancel
            </.ui_button>
            <.ui_button type="submit" size="sm" variant="primary">Save</.ui_button>
          </div>
        </.form>
      </div>
      <.link navigate={~p"/settings/networks/desktop-targets"} class="sr-ui-modal-backdrop">
        Close
      </.link>
    </dialog>
    """
  end

  defp load_page(socket, params) do
    form_options = load_form_options(socket.assigns.current_scope)

    case RemoteAccessDesktopTargets.list_managed(socket.assigns.current_scope) do
      {:ok, targets} ->
        socket
        |> assign(form_options)
        |> assign(:targets, targets)
        |> assign(:loading?, false)
        |> assign_form(params, targets)

      {:error, reason} ->
        socket
        |> assign(form_options)
        |> assign(:targets, [])
        |> assign(:loading?, false)
        |> put_flash(:error, "Failed to load RDP hosts: #{format_error(reason)}")
    end
  end

  defp assign_form(%{assigns: %{form_mode: :new}} = socket, params, _targets) do
    form_params =
      params
      |> default_target_params()
      |> apply_selected_device(socket.assigns.device_option_data)
      |> apply_selected_agent(socket.assigns.agent_option_data)

    socket
    |> assign(:editing_target, nil)
    |> assign(:target_form, target_form(form_params))
  end

  defp assign_form(%{assigns: %{form_mode: :edit}} = socket, params, targets) do
    case Enum.find(targets, &(to_string(&1.id) == to_string(params["id"]))) do
      nil ->
        socket
        |> put_flash(:error, "RDP host not found")
        |> push_patch(to: ~p"/settings/networks/desktop-targets")

      target ->
        socket
        |> assign(:editing_target, target)
        |> assign(:target_form, target_form(target_params(target)))
    end
  end

  defp assign_form(socket, _params, _targets) do
    socket
    |> assign(:editing_target, nil)
    |> assign(:target_form, target_form(default_target_params()))
  end

  defp load_form_options(scope) do
    devices = load_devices(scope)
    agents = load_agents(scope)
    gateways = load_gateways(scope)
    credential_rules = load_credential_rules(scope)

    %{
      device_options: Enum.map(devices, &device_option/1),
      device_option_data: Map.new(devices, &device_option_data/1),
      agent_options: Enum.map(agents, &agent_option/1),
      agent_option_data: Map.new(agents, &agent_option_data/1),
      gateway_options: Enum.map(gateways, &gateway_option/1),
      credential_rule_options: Enum.map(credential_rules, &credential_rule_option/1)
    }
  end

  defp load_devices(scope) do
    Device
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.sort(hostname: :asc, ip: :asc, uid: :asc)
    |> Ash.Query.limit(2_000)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, devices} -> ash_results(devices)
      _ -> []
    end
  end

  defp load_agents(scope) do
    Agent
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.sort(uid: :asc)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, agents} -> agents |> ash_results() |> Enum.filter(&active_agent?/1)
      _ -> []
    end
  end

  defp load_gateways(scope) do
    Gateway
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, gateways} -> gateways |> ash_results() |> Enum.filter(&active_gateway?/1)
      _ -> []
    end
  end

  defp load_credential_rules(scope) do
    NetworkCredentialRule
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.filter(enabled == true and purpose in ["console_access", "generic"])
    |> Ash.Query.sort(priority: :asc, name: :asc)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, rules} -> ash_results(rules)
      _ -> []
    end
  end

  defp ash_results(%Ash.Page.Keyset{results: results}), do: results
  defp ash_results(results) when is_list(results), do: results
  defp ash_results(_results), do: []

  defp active_agent?(%Agent{last_seen_time: %DateTime{} = last_seen_time, status: status})
       when status in [:connected, :degraded, :connecting] do
    DateTime.diff(DateTime.utc_now(), last_seen_time, :minute) <= 30
  end

  defp active_agent?(%Agent{status: status}) when status in [:connected, :degraded], do: true
  defp active_agent?(_agent), do: false

  defp active_gateway?(%Gateway{last_seen: %DateTime{} = last_seen, status: status})
       when status in [:healthy, :degraded] do
    DateTime.diff(DateTime.utc_now(), last_seen, :minute) <= 30
  end

  defp active_gateway?(%Gateway{status: :healthy}), do: true
  defp active_gateway?(_gateway), do: false

  defp device_option(%Device{} = device), do: {device_label(device), device.uid}

  defp device_option_data(%Device{} = device) do
    {device.uid,
     %{
       "name" => first_non_empty([device.hostname, device.name, device.ip, device.uid]),
       "target_host" => first_non_empty([device.ip, device.hostname]),
       "agent_id" => blank_to_string(device.availability_source_agent_id || device.agent_id),
       "gateway_id" => blank_to_string(device.gateway_id)
     }}
  end

  defp agent_option(%Agent{} = agent), do: {agent_label(agent), agent.uid}

  defp agent_option_data(%Agent{} = agent) do
    {agent.uid, %{"gateway_id" => blank_to_string(agent.gateway_id)}}
  end

  defp gateway_option(%Gateway{} = gateway) do
    label =
      [gateway.component_id, gateway.id, gateway.status]
      |> Enum.reject(&empty_label_part?/1)
      |> Enum.join(" - ")

    {label, gateway.id}
  end

  defp credential_rule_option(%NetworkCredentialRule{} = rule) do
    route =
      [rule.scope_type, rule.scope_value]
      |> Enum.reject(&empty_label_part?/1)
      |> Enum.join(":")

    label =
      [rule.name, rule.provider, route]
      |> Enum.reject(&empty_label_part?/1)
      |> Enum.join(" - ")

    {label, rule.id}
  end

  defp device_label(%Device{} = device) do
    [first_non_empty([device.hostname, device.name, device.ip, device.uid]), device.ip, device.type]
    |> Enum.reject(&empty_label_part?/1)
    |> Enum.uniq()
    |> Enum.join(" - ")
  end

  defp agent_label(%Agent{} = agent) do
    status = if is_nil(agent.status), do: nil, else: to_string(agent.status)

    [agent.name, agent.uid, agent.host || agent.ip, status]
    |> Enum.reject(&empty_label_part?/1)
    |> Enum.uniq()
    |> Enum.join(" - ")
  end

  defp apply_selected_device(params, device_data) when is_map(params) and is_map(device_data) do
    selected = blank_to_nil(params["device_uid"])
    data = if selected, do: Map.get(device_data, selected, %{}), else: %{}
    default_name = Map.get(data, "name")

    params
    |> put_if_blank("target_host", Map.get(data, "target_host"))
    |> put_if_blank("agent_id", Map.get(data, "agent_id"))
    |> put_if_blank("gateway_id", Map.get(data, "gateway_id"))
    |> put_if_blank("name", if(default_name, do: "#{default_name} RDP"))
  end

  defp apply_selected_agent(params, agent_data) when is_map(params) and is_map(agent_data) do
    selected = blank_to_nil(params["agent_id"])
    data = if selected, do: Map.get(agent_data, selected, %{}), else: %{}

    put_if_blank(params, "gateway_id", Map.get(data, "gateway_id"))
  end

  defp put_if_blank(params, _key, nil), do: params
  defp put_if_blank(params, _key, ""), do: params

  defp put_if_blank(params, key, value) do
    case blank_to_nil(params[key]) do
      nil -> Map.put(params, key, value)
      _ -> params
    end
  end

  defp save_target(%{assigns: %{form_mode: :new}} = socket, attrs) do
    case RemoteAccessDesktopTargets.create_managed(socket.assigns.current_scope, attrs) do
      {:ok, _target} ->
        {:noreply,
         socket
         |> put_flash(:info, "RDP host created")
         |> push_patch(to: ~p"/settings/networks/desktop-targets")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create RDP host: #{format_error(reason)}")}
    end
  end

  defp save_target(%{assigns: %{form_mode: :edit, editing_target: %RemoteAccessDesktopTarget{} = target}} = socket, attrs) do
    attrs = merge_existing_target_metadata(attrs, target)

    case RemoteAccessDesktopTargets.update_managed(socket.assigns.current_scope, target, attrs) do
      {:ok, _target} ->
        {:noreply,
         socket
         |> put_flash(:info, "RDP host updated")
         |> push_patch(to: ~p"/settings/networks/desktop-targets")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update RDP host: #{format_error(reason)}")}
    end
  end

  defp save_target(socket, _attrs) do
    {:noreply, put_flash(socket, :error, "No RDP host selected")}
  end

  defp set_enabled(socket, id, enabled, success_message) do
    with %RemoteAccessDesktopTarget{} = target <-
           Enum.find(socket.assigns.targets, &(to_string(&1.id) == to_string(id))),
         {:ok, _target} <-
           RemoteAccessDesktopTargets.set_managed_enabled(
             socket.assigns.current_scope,
             target,
             enabled
           ) do
      {:noreply,
       socket
       |> put_flash(:info, success_message)
       |> load_page(%{})}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "RDP host not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update RDP host: #{format_error(reason)}")}
    end
  end

  defp normalize_target_attrs(params) do
    with {:ok, name} <- required_string(params, "name"),
         {:ok, device_uid} <- required_string(params, "device_uid"),
         {:ok, target_host} <- required_string(params, "target_host"),
         {:ok, target_port} <- parse_port(params["target_port"]),
         {:ok, target_kind} <- enum_value(params["target_kind"], @target_kinds, "target_kind"),
         {:ok, credential_mode} <-
           enum_value(
             params["credential_custody_mode"],
             @credential_modes,
             "credential_custody_mode"
           ),
         {:ok, credential_rule_id} <- optional_uuid(params["credential_rule_id"]),
         :ok <- validate_credential_rule_selection(credential_mode, credential_rule_id),
         {:ok, kdc_proxy_url} <- optional_kdc_proxy_url(params["kdc_proxy_url"]),
         {:ok, kerberos_hostname} <- optional_kerberos_hostname(params["kerberos_hostname"]),
         {:ok, target_tls} <- target_tls_policy(params) do
      {:ok,
       %{
         name: name,
         description: blank_to_nil(params["description"]),
         enabled: truthy?(params["enabled"]),
         target_kind: target_kind,
         device_uid: device_uid,
         target_host: target_host,
         target_port: target_port,
         agent_id: blank_to_nil(params["agent_id"]),
         gateway_id: blank_to_nil(params["gateway_id"]),
         credential_custody_mode: credential_mode,
         credential_rule_id: credential_rule_id,
         approval_required: false,
         allowed_principals: split_principals(params["allowed_principals"]),
         target_tls: target_tls,
         nla: %{"required" => truthy?(params["nla_required"])},
         screen_policy: screen_policy(params),
         redirection_policy: %{
           "clipboard" => safe_option(params["clipboard"], @clipboard_modes, "disabled")
         },
         recording_policy: %{
           "mode" => safe_option(params["recording_mode"], @recording_modes, "metadata_only")
         },
         metadata: rdp_kerberos_metadata(kdc_proxy_url, kerberos_hostname)
       }}
    end
  end

  defp merge_existing_target_metadata(%{metadata: metadata} = attrs, %RemoteAccessDesktopTarget{} = target)
       when is_map(metadata) do
    existing =
      target.metadata
      |> normalize_metadata()
      |> Map.drop(["rdp.kdc_proxy_url", "rdp.kerberos_hostname"])

    Map.put(attrs, :metadata, Map.merge(existing, metadata))
  end

  defp merge_existing_target_metadata(attrs, _target), do: attrs

  defp required_string(params, key) do
    case blank_to_nil(params[key]) do
      nil -> {:error, "Required fields are missing"}
      value -> {:ok, value}
    end
  end

  defp parse_port(value) do
    case parse_positive_integer(value) do
      port when is_integer(port) and port <= 65_535 -> {:ok, port}
      _ -> {:error, "Target port must be between 1 and 65535"}
    end
  end

  defp optional_uuid(value) do
    case blank_to_nil(value) do
      nil ->
        {:ok, nil}

      value ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> {:error, "Credential rule is invalid"}
        end
    end
  end

  defp validate_credential_rule_selection(:centrally_brokered, nil),
    do: {:error, "Choose a credential rule or use Prompt user when connecting"}

  defp validate_credential_rule_selection(_credential_mode, _credential_rule_id), do: :ok

  defp enum_value(value, allowed, field) do
    value = blank_to_nil(value)

    case Map.fetch(allowed, value) do
      {:ok, enum} -> {:ok, enum}
      :error -> {:error, "#{field} is invalid"}
    end
  end

  defp screen_policy(params) do
    %{}
    |> put_positive_integer("max_width", params["max_width"])
    |> put_positive_integer("max_height", params["max_height"])
    |> put_positive_integer("frame_rate", params["frame_rate"])
    |> put_positive_integer("bitrate_kbps", params["bitrate_kbps"])
  end

  defp put_positive_integer(map, key, value) do
    case parse_positive_integer(value) do
      integer when is_integer(integer) -> Map.put(map, key, integer)
      nil -> map
    end
  end

  defp rdp_kerberos_metadata(kdc_proxy_url, kerberos_hostname) do
    %{}
    |> put_metadata_string("rdp.kdc_proxy_url", kdc_proxy_url)
    |> put_metadata_string("rdp.kerberos_hostname", kerberos_hostname)
  end

  defp put_metadata_string(map, key, value) do
    case blank_to_nil(value) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp target_tls_policy(params) do
    ca_bundle_id =
      params["target_tls_ca_bundle_id"]
      |> blank_to_nil()
      |> generated_ca_bundle_id(params)

    ca_bundle_pem = blank_to_nil(params["target_tls_ca_bundle_pem"])

    if ca_bundle_id_present?(ca_bundle_id) == ca_bundle_pem_present?(ca_bundle_pem) do
      {:ok,
       %{"mode" => safe_option(params["target_tls_mode"], @target_tls_modes, "verify_ca")}
       |> put_policy_string("server_name", params["target_tls_server_name"])
       |> put_policy_string("ca_bundle_id", ca_bundle_id)
       |> put_policy_string("ca_bundle_pem", ca_bundle_pem)}
    else
      {:error, "CA certificate and generated bundle identifier must be provided together"}
    end
  end

  defp ca_bundle_id_present?(value), do: not is_nil(value)
  defp ca_bundle_pem_present?(value), do: not is_nil(value)

  defp generated_ca_bundle_id(nil, params) do
    if blank_to_nil(params["target_tls_ca_bundle_pem"]) do
      source =
        first_non_empty([
          params["target_tls_server_name"],
          params["target_host"],
          params["name"],
          "rdp-ca"
        ])

      "rdp-ca-" <> slugify(source)
    end
  end

  defp generated_ca_bundle_id(value, _params), do: value

  defp put_policy_string(map, key, value) do
    case blank_to_nil(value) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp optional_kdc_proxy_url(value) do
    case blank_to_nil(value) do
      nil ->
        {:ok, nil}

      value ->
        uri = URI.parse(value)

        cond do
          uri.scheme != "tcp" ->
            {:error, "KDC Proxy URL must use tcp://"}

          blank_to_nil(uri.host) == nil ->
            {:error, "KDC Proxy URL must include a host"}

          uri.userinfo || uri.path not in [nil, ""] || uri.query || uri.fragment ->
            {:error, "KDC Proxy URL must be a tcp://host[:port] endpoint"}

          true ->
            {:ok, value}
        end
    end
  end

  defp optional_kerberos_hostname(value), do: {:ok, blank_to_nil(value)}

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp default_target_params(params \\ %{}) do
    params = Map.new(params || %{})

    Map.merge(
      %{
        "name" => "",
        "description" => "",
        "enabled" => "true",
        "target_kind" => "inventory_device",
        "device_uid" => "",
        "target_host" => "",
        "target_port" => "3389",
        "agent_id" => "",
        "gateway_id" => "",
        "credential_custody_mode" => "user_present",
        "credential_rule_id" => "",
        "target_tls_mode" => "verify_ca",
        "target_tls_server_name" => "",
        "target_tls_ca_bundle_id" => "",
        "target_tls_ca_bundle_pem" => "",
        "nla_required" => "true",
        "recording_mode" => "metadata_only",
        "kdc_proxy_url" => "",
        "kerberos_hostname" => "",
        "max_width" => "",
        "max_height" => "",
        "frame_rate" => "",
        "bitrate_kbps" => "",
        "clipboard" => "disabled",
        "allowed_principals" => ""
      },
      Map.take(params, default_target_prefill_keys())
    )
  end

  defp default_target_prefill_keys do
    [
      "name",
      "description",
      "device_uid",
      "target_host",
      "target_port",
      "agent_id",
      "gateway_id",
      "target_tls_server_name"
    ]
  end

  defp target_params(%RemoteAccessDesktopTarget{} = target) do
    Map.merge(default_target_params(), %{
      "name" => target.name || "",
      "description" => target.description || "",
      "enabled" => if(target.enabled, do: "true", else: "false"),
      "target_kind" => to_string(target.target_kind || :inventory_device),
      "device_uid" => target.device_uid || "",
      "target_host" => target.target_host || "",
      "target_port" => to_string(target.target_port || 3389),
      "agent_id" => target.agent_id || "",
      "gateway_id" => target.gateway_id || "",
      "credential_custody_mode" => to_string(target.credential_custody_mode || :user_present),
      "credential_rule_id" => target.credential_rule_id || "",
      "target_tls_mode" => policy_value(target.target_tls, "mode", "verify_ca"),
      "target_tls_server_name" =>
        policy_value(target.target_tls, "server_name", nil) ||
          policy_value(target.target_tls, "server", ""),
      "target_tls_ca_bundle_id" => policy_value(target.target_tls, "ca_bundle_id", ""),
      "target_tls_ca_bundle_pem" => policy_value(target.target_tls, "ca_bundle_pem", ""),
      "nla_required" => if(policy_value(target.nla, "required", true), do: "true", else: "false"),
      "recording_mode" => policy_value(target.recording_policy, "mode", "metadata_only"),
      "kdc_proxy_url" => policy_value(target.metadata, "rdp.kdc_proxy_url", ""),
      "kerberos_hostname" => policy_value(target.metadata, "rdp.kerberos_hostname", ""),
      "max_width" => policy_number(target.screen_policy, "max_width"),
      "max_height" => policy_number(target.screen_policy, "max_height"),
      "frame_rate" => policy_number(target.screen_policy, "frame_rate"),
      "bitrate_kbps" => policy_number(target.screen_policy, "bitrate_kbps"),
      "clipboard" => policy_value(target.redirection_policy, "clipboard", "disabled"),
      "allowed_principals" => Enum.join(target.allowed_principals || [], "\n")
    })
  end

  defp normalize_form_params(params), do: Map.merge(default_target_params(), Map.new(params))
  defp target_form(params), do: to_form(normalize_form_params(params), as: :desktop_target)

  defp split_principals(value) when is_binary(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_principals(_value), do: []

  defp safe_option(value, allowed, default) do
    value = blank_to_nil(value) || default
    if value in allowed, do: value, else: default
  end

  defp truthy?(value) when value in [true, "true", "1", "yes", "on"], do: true
  defp truthy?(_value), do: false

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  defp blank_to_string(value) do
    blank_to_nil(value) || ""
  end

  defp first_non_empty(values) when is_list(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when is_atom(value) ->
        value |> to_string() |> blank_to_nil()

      value when not is_nil(value) ->
        value |> to_string() |> blank_to_nil()

      _ ->
        nil
    end)
  end

  defp empty_label_part?(nil), do: true
  defp empty_label_part?(value) when is_binary(value), do: String.trim(value) == ""
  defp empty_label_part?(_value), do: false

  defp slugify(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "rdp-ca"
      slug -> slug
    end
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp policy_value(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp policy_value(_map, _key, default), do: default

  defp policy_number(map, key) do
    case policy_value(map, key, nil) do
      value when is_integer(value) -> to_string(value)
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp enum_options(values), do: Enum.map(values, &{enum_label(&1), &1})

  defp enum_label(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp authorize_manage_event(socket, fun) when is_function(fun, 0) do
    if fresh_can_manage?(socket.assigns.current_scope) do
      fun.()
    else
      {:noreply, unauthorized(socket)}
    end
  end

  defp unauthorized(socket) do
    socket
    |> put_flash(:error, "Not authorized to manage RDP hosts")
    |> redirect(to: ~p"/settings/profile")
  end

  defp fresh_can_manage?(%{user: user}) when not is_nil(user) do
    ServiceRadar.Identity.RBAC.clear_process_cache()
    ServiceRadar.Identity.RBAC.has_permission?(user, @manage_permission)
  end

  defp fresh_can_manage?(scope), do: can_manage?(scope)

  defp can_manage?(scope), do: RBAC.can?(scope, @manage_permission)

  defp format_error(%Ash.Error.Invalid{} = error), do: Exception.message(error)
  defp format_error(%Ash.Error.Forbidden{} = error), do: Exception.message(error)
  defp format_error(reason) when is_binary(reason), do: reason

  defp format_error(reason) when is_atom(reason), do: reason |> to_string() |> String.replace("_", " ")

  defp format_error(reason), do: inspect(reason)
end
