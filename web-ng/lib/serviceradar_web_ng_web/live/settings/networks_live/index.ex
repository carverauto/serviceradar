defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index do
  @moduledoc """
  LiveView for managing network sweep configuration.

  Provides UI for:
  - Sweep Groups: User-configured scan jobs with schedules and targeting
  - Scanner Profiles: Admin-managed scan configuration templates
  - Active Scans: Real-time view of running sweeps
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias AshPhoenix.Form
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadar.SweepJobs.{SweepGroup, SweepGroupExecution, SweepProfile, SweepPubSub}

  @refresh_interval :timer.seconds(15)

  @criteria_fields [
    {"Tags", "tags"},
    {"Discovery Source", "discovery_sources"},
    {"Hostname", "hostname"},
    {"IP Address", "ip"},
    {"MAC Address", "mac"},
    {"Device UID", "uid"},
    {"Gateway ID", "gateway_id"},
    {"Agent ID", "agent_id"},
    {"Availability", "is_available"},
    {"Device Type", "type"},
    {"Type ID", "type_id"},
    {"Vendor", "vendor_name"},
    {"Model", "model"},
    {"Risk Level", "risk_level"},
    {"OS Name", "os.name"},
    {"OS Version", "os.version"},
    {"OS Type", "os.type"},
    {"CPU Type", "hw_info.cpu_type"},
    {"CPU Arch", "hw_info.cpu_architecture"},
    {"Serial Number", "hw_info.serial_number"}
  ]

  @text_operators [
    {"contains", "contains"},
    {"does not contain", "not_contains"},
    {"equals", "eq"},
    {"not equals", "neq"},
    {"starts with", "starts_with"},
    {"ends with", "ends_with"},
    {"in list", "in"},
    {"not in list", "not_in"}
  ]

  @tag_operators [
    {"has any", "has_any"},
    {"has all", "has_all"}
  ]

  @discovery_operators [
    {"contains", "contains"},
    {"does not contain", "not_contains"},
    {"in list", "in"},
    {"not in list", "not_in"}
  ]

  @ip_operators [
    {"equals", "eq"},
    {"not equals", "neq"},
    {"contains", "contains"},
    {"in CIDR", "in_cidr"},
    {"not in CIDR", "not_in_cidr"},
    {"in range", "in_range"}
  ]

  @boolean_operators [
    {"is", "eq"},
    {"is not", "neq"}
  ]

  @numeric_operators [
    {"equals", "eq"},
    {"not equals", "neq"},
    {">", "gt"},
    {">=", "gte"},
    {"<", "lt"},
    {"<=", "lte"}
  ]

  @numeric_fields ~w(type_id)
  @boolean_fields ~w(is_available)
  @list_operators ~w(in not_in has_any has_all)

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    tenant_id = Scope.tenant_id(scope)

    if connected?(socket) do
      # Subscribe to tenant-specific sweep updates
      if tenant_id do
        SweepPubSub.subscribe(tenant_id)
      end

      # Refresh active scans periodically (fallback for any missed events)
      :timer.send_interval(@refresh_interval, self(), :refresh_active_scans)
    end

    socket =
      socket
      |> assign(:page_title, "Network Sweeps")
      |> assign(:active_tab, :groups)
      |> assign(:sweep_groups, load_sweep_groups(scope))
      |> assign(:sweep_profiles, load_sweep_profiles(scope))
      |> assign(:running_executions, load_running_executions(scope))
      |> assign(:recent_executions, load_recent_executions(scope))
      # Track real-time progress for running executions (execution_id -> progress_data)
      |> assign(:execution_progress, %{})
      |> assign(:selected_group, nil)
      |> assign(:selected_profile, nil)
      |> assign(:show_form, nil)
      |> assign(:ash_form, nil)
      |> assign(:form, nil)
      # Criteria builder state
      |> assign(:criteria_rules, [])
      |> assign(:target_count, nil)
      |> assign(:target_count_loading, false)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Network Sweeps")
    |> assign(:show_form, nil)
    |> assign(:ash_form, nil)
    |> assign(:selected_group, nil)
    |> assign(:selected_profile, nil)
  end

  defp apply_action(socket, :new_group, _params) do
    scope = socket.assigns.current_scope
    ash_form = Form.for_create(SweepGroup, :create, domain: ServiceRadar.SweepJobs, scope: scope)

    socket
    |> assign(:page_title, "New Sweep Group")
    |> assign(:show_form, :new_group)
    |> assign(:ash_form, ash_form)
    |> assign(:form, to_form(ash_form))
    |> assign(:criteria_rules, [])
    |> assign(:target_count, nil)
  end

  defp apply_action(socket, :edit_group, %{"id" => id}) do
    case load_sweep_group(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, "Sweep group not found")
        |> push_navigate(to: ~p"/settings/networks")

      group ->
        scope = socket.assigns.current_scope
        ash_form = Form.for_update(group, :update, domain: ServiceRadar.SweepJobs, scope: scope)
        rules = criteria_to_rules(group.target_criteria || %{})

        socket
        |> assign(:page_title, "Edit Sweep Group")
        |> assign(:show_form, :edit_group)
        |> assign(:selected_group, group)
        |> assign(:ash_form, ash_form)
        |> assign(:form, to_form(ash_form))
        |> assign(:criteria_rules, rules)
        |> assign(:target_count, nil)
    end
  end

  defp apply_action(socket, :show_group, %{"id" => id}) do
    case load_sweep_group(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, "Sweep group not found")
        |> push_navigate(to: ~p"/settings/networks")

      group ->
        socket
        |> assign(:page_title, group.name)
        |> assign(:show_form, :show_group)
        |> assign(:selected_group, group)
    end
  end

  defp apply_action(socket, :new_profile, _params) do
    scope = socket.assigns.current_scope

    ash_form =
      Form.for_create(SweepProfile, :create, domain: ServiceRadar.SweepJobs, scope: scope)

    socket
    |> assign(:page_title, "New Scanner Profile")
    |> assign(:show_form, :new_profile)
    |> assign(:ash_form, ash_form)
    |> assign(:form, to_form(ash_form))
  end

  defp apply_action(socket, :edit_profile, %{"id" => id}) do
    case load_sweep_profile(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, "Scanner profile not found")
        |> push_navigate(to: ~p"/settings/networks")

      profile ->
        scope = socket.assigns.current_scope
        ash_form = Form.for_update(profile, :update, domain: ServiceRadar.SweepJobs, scope: scope)

        socket
        |> assign(:page_title, "Edit Scanner Profile")
        |> assign(:show_form, :edit_profile)
        |> assign(:selected_profile, profile)
        |> assign(:ash_form, ash_form)
        |> assign(:form, to_form(ash_form))
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_atom(tab))}
  end

  def handle_event("toggle_group", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case load_sweep_group(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Sweep group not found")}

      group ->
        action = if group.enabled, do: :disable, else: :enable

        case Ash.update(group, action, scope: scope) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> assign(:sweep_groups, load_sweep_groups(scope))
             |> put_flash(
               :info,
               "Sweep group #{if action == :enable, do: "enabled", else: "disabled"}"
             )}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to update sweep group")}
        end
    end
  end

  def handle_event("delete_group", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case load_sweep_group(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Sweep group not found")}

      group ->
        case Ash.destroy(group, scope: scope) do
          :ok ->
            {:noreply,
             socket
             |> assign(:sweep_groups, load_sweep_groups(scope))
             |> put_flash(:info, "Sweep group deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete sweep group")}
        end
    end
  end

  def handle_event("delete_profile", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case load_sweep_profile(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Scanner profile not found")}

      profile ->
        case Ash.destroy(profile, scope: scope) do
          :ok ->
            {:noreply,
             socket
             |> assign(:sweep_profiles, load_sweep_profiles(scope))
             |> put_flash(:info, "Scanner profile deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete scanner profile")}
        end
    end
  end

  def handle_event("save_group", %{"form" => params}, socket) do
    scope = socket.assigns.current_scope
    # Convert criteria rules to target_criteria map
    target_criteria = rules_to_criteria(socket.assigns.criteria_rules)

    params =
      params
      |> Map.put("target_criteria", target_criteria)
      |> normalize_static_targets()

    ash_form =
      socket.assigns.ash_form
      |> Form.validate(params)

    case Form.submit(ash_form, params: params) do
      {:ok, _group} ->
        {:noreply,
         socket
         |> assign(:sweep_groups, load_sweep_groups(scope))
         |> assign(:criteria_rules, [])
         |> put_flash(:info, "Sweep group saved")
         |> push_navigate(to: ~p"/settings/networks")}

      {:error, ash_form} ->
        {:noreply,
         socket
         |> assign(:ash_form, ash_form)
         |> assign(:form, to_form(ash_form))}
    end
  end

  def handle_event("save_profile", %{"form" => params}, socket) do
    scope = socket.assigns.current_scope

    ash_form =
      socket.assigns.ash_form
      |> Form.validate(params)

    case Form.submit(ash_form, params: params) do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> assign(:sweep_profiles, load_sweep_profiles(scope))
         |> put_flash(:info, "Scanner profile saved")
         |> push_navigate(to: ~p"/settings/networks")}

      {:error, ash_form} ->
        {:noreply,
         socket
         |> assign(:ash_form, ash_form)
         |> assign(:form, to_form(ash_form))}
    end
  end

  def handle_event("validate_group", %{"form" => params}, socket) do
    target_criteria = rules_to_criteria(socket.assigns.criteria_rules)

    params =
      params
      |> Map.put("target_criteria", target_criteria)
      |> normalize_static_targets()

    ash_form =
      socket.assigns.ash_form
      |> Form.validate(params)

    {:noreply,
     socket
     |> assign(:ash_form, ash_form)
     |> assign(:form, to_form(ash_form))}
  end

  def handle_event("validate_profile", %{"form" => params}, socket) do
    ash_form =
      socket.assigns.ash_form
      |> Form.validate(params)

    {:noreply,
     socket
     |> assign(:ash_form, ash_form)
     |> assign(:form, to_form(ash_form))}
  end

  # Criteria builder handlers
  def handle_event("add_criteria_rule", _params, socket) do
    new_rule = %{
      id: System.unique_integer([:positive]),
      field: default_criteria_field(),
      operator: default_operator_for(default_criteria_field()),
      value: ""
    }

    rules = socket.assigns.criteria_rules ++ [new_rule]
    {:noreply, assign(socket, :criteria_rules, rules)}
  end

  def handle_event("remove_criteria_rule", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    rules = Enum.reject(socket.assigns.criteria_rules, &(&1.id == id))

    socket =
      socket
      |> assign(:criteria_rules, rules)
      |> maybe_update_target_count()

    {:noreply, socket}
  end

  def handle_event("update_criteria_rule", params, socket) do
    id = String.to_integer(params["id"])
    field = params["field"]
    operator = params["operator"]
    value = Map.get(params, "value")

    rules =
      Enum.map(socket.assigns.criteria_rules, fn rule ->
        apply_rule_update(rule, id, field, operator, value)
      end)

    socket =
      socket
      |> assign(:criteria_rules, rules)
      |> maybe_update_target_count()

    {:noreply, socket}
  end

  def handle_event("preview_targets", _params, socket) do
    {:noreply, update_target_count(socket)}
  end

  defp maybe_update_target_count(socket) do
    # Auto-update count when rules change and have values
    rules = socket.assigns.criteria_rules

    if Enum.any?(rules, &rule_active?/1) do
      update_target_count(socket)
    else
      assign(socket, :target_count, nil)
    end
  end

  defp apply_rule_update(rule, id, _field, _operator, _value) when rule.id != id, do: rule

  defp apply_rule_update(rule, _id, field, operator, value) do
    rule
    |> maybe_update_rule_field(field)
    |> maybe_update_rule_operator(operator)
    |> maybe_update_rule_value(value)
  end

  defp maybe_update_rule_field(rule, nil), do: rule
  defp maybe_update_rule_field(rule, field) when field == rule.field, do: rule

  defp maybe_update_rule_field(rule, field) do
    new_value = if boolean_field?(field), do: "true", else: ""

    %{
      rule
      | field: field,
        operator: default_operator_for(field),
        value: new_value
    }
  end

  defp maybe_update_rule_operator(rule, nil), do: rule

  defp maybe_update_rule_operator(rule, operator) do
    %{rule | operator: ensure_operator_for_field(rule.field, operator)}
  end

  defp maybe_update_rule_value(rule, nil), do: rule
  defp maybe_update_rule_value(rule, value), do: %{rule | value: value}

  defp update_target_count(socket) do
    criteria = rules_to_criteria(socket.assigns.criteria_rules)

    if criteria == %{} do
      assign(socket, :target_count, nil)
    else
      scope = socket.assigns.current_scope
      count = get_matching_device_count(scope, criteria)
      assign(socket, :target_count, count)
    end
  end

  @impl true
  def handle_info(:refresh_active_scans, socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(:running_executions, load_running_executions(scope))
     |> assign(:recent_executions, load_recent_executions(scope))}
  end

  # Handle sweep execution started event
  def handle_info({:sweep_execution_started, execution_data}, socket) do
    scope = socket.assigns.current_scope

    # Initialize progress tracking for this execution
    progress =
      Map.put(socket.assigns.execution_progress, execution_data.execution_id, %{
        batch_num: 0,
        total_batches: nil,
        hosts_processed: 0,
        hosts_available: 0,
        hosts_failed: 0,
        started_at: execution_data.started_at
      })

    {:noreply,
     socket
     |> assign(:execution_progress, progress)
     |> assign(:running_executions, load_running_executions(scope))}
  end

  # Handle sweep execution progress event (real-time batch updates)
  def handle_info({:sweep_execution_progress, progress_data}, socket) do
    execution_id = progress_data.execution_id

    # Update progress tracking for this execution
    progress =
      Map.put(socket.assigns.execution_progress, execution_id, %{
        batch_num: progress_data.batch_num,
        total_batches: progress_data.total_batches,
        hosts_processed: progress_data.hosts_processed,
        hosts_available: progress_data.hosts_available,
        hosts_failed: progress_data.hosts_failed,
        devices_created: progress_data[:devices_created] || 0,
        devices_updated: progress_data[:devices_updated] || 0,
        updated_at: progress_data.updated_at
      })

    {:noreply, assign(socket, :execution_progress, progress)}
  end

  # Handle sweep execution completed event
  def handle_info({:sweep_execution_completed, execution_data}, socket) do
    scope = socket.assigns.current_scope
    execution_id = execution_data.execution_id

    # Remove from progress tracking
    progress = Map.delete(socket.assigns.execution_progress, execution_id)

    {:noreply,
     socket
     |> assign(:execution_progress, progress)
     |> assign(:running_executions, load_running_executions(scope))
     |> assign(:recent_executions, load_recent_executions(scope))}
  end

  # Handle sweep execution failed event
  def handle_info({:sweep_execution_failed, execution_data}, socket) do
    scope = socket.assigns.current_scope
    execution_id = execution_data.execution_id

    # Remove from progress tracking
    progress = Map.delete(socket.assigns.execution_progress, execution_id)

    {:noreply,
     socket
     |> assign(:execution_progress, progress)
     |> assign(:running_executions, load_running_executions(scope))
     |> assign(:recent_executions, load_recent_executions(scope))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path="/settings/networks">
        <.settings_nav current_path="/settings/networks" />

        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">Network Sweeps</h1>
            <p class="text-sm text-base-content/60">
              Configure network discovery sweeps and scanner profiles.
            </p>
          </div>
        </div>

        <%= if @show_form in [:new_group, :edit_group] do %>
          <.group_form
            form={@form}
            show_form={@show_form}
            profiles={@sweep_profiles}
            criteria_rules={@criteria_rules}
            target_count={@target_count}
          />
        <% else %>
          <%= if @show_form in [:new_profile, :edit_profile] do %>
            <.profile_form form={@form} show_form={@show_form} />
          <% else %>
            <%= if @show_form == :show_group do %>
              <.group_detail group={@selected_group} />
            <% else %>
              <.tab_navigation active_tab={@active_tab} running_count={length(@running_executions)} />

              <%= case @active_tab do %>
                <% :groups -> %>
                  <.sweep_groups_panel groups={@sweep_groups} />
                <% :profiles -> %>
                  <.profiles_panel profiles={@sweep_profiles} />
                <% :active_scans -> %>
                  <.active_scans_panel
                    running={@running_executions}
                    recent={@recent_executions}
                    groups={@sweep_groups}
                    execution_progress={@execution_progress}
                  />
              <% end %>
            <% end %>
          <% end %>
        <% end %>
      </.settings_shell>
    </Layouts.app>
    """
  end

  # Tab Navigation
  attr :active_tab, :atom, required: true
  attr :running_count, :integer, default: 0

  defp tab_navigation(assigns) do
    ~H"""
    <div class="flex items-center gap-2 border-b border-base-200">
      <button
        phx-click="switch_tab"
        phx-value-tab="groups"
        class={"px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors " <>
               if(@active_tab == :groups, do: "border-primary text-primary", else: "border-transparent text-base-content/60 hover:text-base-content")}
      >
        Sweep Groups
      </button>
      <button
        phx-click="switch_tab"
        phx-value-tab="profiles"
        class={"px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors " <>
               if(@active_tab == :profiles, do: "border-primary text-primary", else: "border-transparent text-base-content/60 hover:text-base-content")}
      >
        Scanner Profiles
      </button>
      <button
        phx-click="switch_tab"
        phx-value-tab="active_scans"
        class={"px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors flex items-center gap-1.5 " <>
               if(@active_tab == :active_scans, do: "border-primary text-primary", else: "border-transparent text-base-content/60 hover:text-base-content")}
      >
        Active Scans
        <span
          :if={@running_count > 0}
          class="inline-flex items-center justify-center px-1.5 py-0.5 text-xs font-semibold rounded-full bg-success text-success-content animate-pulse"
        >
          {@running_count}
        </span>
      </button>
    </div>
    """
  end

  # Sweep Groups Panel
  attr :groups, :list, required: true

  defp sweep_groups_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center justify-between w-full">
          <div>
            <div class="text-sm font-semibold">Sweep Groups</div>
            <p class="text-xs text-base-content/60">
              {length(@groups)} group(s) configured
            </p>
          </div>
          <.link navigate={~p"/settings/networks/groups/new"}>
            <.ui_button variant="primary" size="sm">
              <.icon name="hero-plus" class="size-4" /> New Group
            </.ui_button>
          </.link>
        </div>
      </:header>

      <div class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr class="text-xs uppercase tracking-wide text-base-content/60">
              <th>Status</th>
              <th>Name</th>
              <th>Schedule</th>
              <th>Partition</th>
              <th>Last Run</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@groups == []}>
              <td colspan="6" class="text-center text-base-content/60 py-8">
                No sweep groups configured. Create one to start scanning your network.
              </td>
            </tr>
            <%= for group <- @groups do %>
              <tr class="hover:bg-base-200/40">
                <td>
                  <button
                    phx-click="toggle_group"
                    phx-value-id={group.id}
                    class="flex items-center gap-1.5 cursor-pointer"
                  >
                    <span class={"size-2 rounded-full #{if group.enabled, do: "bg-success", else: "bg-base-content/30"}"}>
                    </span>
                    <span class="text-xs">{if group.enabled, do: "Enabled", else: "Disabled"}</span>
                  </button>
                </td>
                <td>
                  <.link
                    navigate={~p"/settings/networks/groups/#{group.id}"}
                    class="font-medium hover:text-primary"
                  >
                    {group.name}
                  </.link>
                  <p :if={group.description} class="text-xs text-base-content/60 truncate max-w-xs">
                    {group.description}
                  </p>
                </td>
                <td class="font-mono text-xs">
                  {format_schedule(group)}
                </td>
                <td class="text-xs">
                  {group.partition}
                </td>
                <td class="text-xs text-base-content/60">
                  {format_last_run(group.last_run_at)}
                </td>
                <td>
                  <div class="flex items-center gap-1">
                    <.link navigate={~p"/settings/networks/groups/#{group.id}/edit"}>
                      <.ui_button variant="ghost" size="xs">
                        <.icon name="hero-pencil" class="size-3" />
                      </.ui_button>
                    </.link>
                    <.ui_button
                      variant="ghost"
                      size="xs"
                      phx-click="delete_group"
                      phx-value-id={group.id}
                      data-confirm="Are you sure you want to delete this sweep group?"
                    >
                      <.icon name="hero-trash" class="size-3" />
                    </.ui_button>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </.ui_panel>
    """
  end

  # Scanner Profiles Panel
  attr :profiles, :list, required: true

  defp profiles_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center justify-between w-full">
          <div>
            <div class="text-sm font-semibold">Scanner Profiles</div>
            <p class="text-xs text-base-content/60">
              {length(@profiles)} profile(s) available
            </p>
          </div>
          <.link navigate={~p"/settings/networks/profiles/new"}>
            <.ui_button variant="primary" size="sm">
              <.icon name="hero-plus" class="size-4" /> New Profile
            </.ui_button>
          </.link>
        </div>
      </:header>

      <div class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr class="text-xs uppercase tracking-wide text-base-content/60">
              <th>Name</th>
              <th>Ports</th>
              <th>Modes</th>
              <th>Settings</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@profiles == []}>
              <td colspan="5" class="text-center text-base-content/60 py-8">
                No scanner profiles configured. Create one to define reusable scan settings.
              </td>
            </tr>
            <%= for profile <- @profiles do %>
              <tr class="hover:bg-base-200/40">
                <td>
                  <div class="font-medium">{profile.name}</div>
                  <p :if={profile.description} class="text-xs text-base-content/60 truncate max-w-xs">
                    {profile.description}
                  </p>
                </td>
                <td class="text-xs font-mono">
                  {format_ports(profile.ports)}
                </td>
                <td>
                  <div class="flex flex-wrap gap-1">
                    <%= for mode <- (profile.sweep_modes || []) do %>
                      <.ui_badge variant="ghost" size="xs">{mode}</.ui_badge>
                    <% end %>
                  </div>
                </td>
                <td class="text-xs">
                  <div>Concurrency: {profile.concurrency}</div>
                  <div>Timeout: {profile.timeout}</div>
                </td>
                <td>
                  <div class="flex items-center gap-1">
                    <.link navigate={~p"/settings/networks/profiles/#{profile.id}/edit"}>
                      <.ui_button variant="ghost" size="xs">
                        <.icon name="hero-pencil" class="size-3" />
                      </.ui_button>
                    </.link>
                    <.ui_button
                      variant="ghost"
                      size="xs"
                      phx-click="delete_profile"
                      phx-value-id={profile.id}
                      data-confirm="Are you sure you want to delete this scanner profile?"
                    >
                      <.icon name="hero-trash" class="size-3" />
                    </.ui_button>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </.ui_panel>
    """
  end

  # Active Scans Panel
  attr :running, :list, required: true
  attr :recent, :list, required: true
  attr :groups, :list, required: true
  attr :execution_progress, :map, default: %{}

  defp active_scans_panel(assigns) do
    # Build a map of group_id -> group for quick lookup
    groups_map = Map.new(assigns.groups, &{&1.id, &1})
    assigns = assign(assigns, :groups_map, groups_map)

    ~H"""
    <div class="space-y-4">
      <!-- Statistics Cards -->
      <.scan_statistics running={@running} recent={@recent} />
      
    <!-- Running Scans -->
      <.ui_panel>
        <:header>
          <div class="flex items-center gap-2">
            <.icon name="hero-play-circle" class="size-5 text-success" />
            <div class="text-sm font-semibold">Running Scans</div>
            <span
              :if={length(@running) > 0}
              class="ml-1 inline-flex items-center justify-center size-5 text-xs font-semibold rounded-full bg-success/20 text-success"
            >
              {length(@running)}
            </span>
          </div>
        </:header>

        <div :if={@running == []} class="py-8 text-center text-base-content/60">
          <.icon name="hero-clock" class="size-8 mx-auto mb-2 opacity-50" />
          <p>No scans currently running</p>
        </div>

        <div :if={@running != []} class="space-y-3">
          <%= for execution <- @running do %>
            <.running_scan_card
              execution={execution}
              group={Map.get(@groups_map, execution.sweep_group_id)}
              progress={Map.get(@execution_progress, execution.id)}
            />
          <% end %>
        </div>
      </.ui_panel>
      
    <!-- Recent Completions -->
      <.ui_panel>
        <:header>
          <div class="flex items-center gap-2">
            <.icon name="hero-clock" class="size-5 text-base-content/60" />
            <div class="text-sm font-semibold">Recent Completions</div>
          </div>
        </:header>

        <div :if={@recent == []} class="py-8 text-center text-base-content/60">
          <.icon name="hero-document-text" class="size-8 mx-auto mb-2 opacity-50" />
          <p>No recent scan executions</p>
        </div>

        <div :if={@recent != []} class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr class="text-xs uppercase tracking-wide text-base-content/60">
                <th>Status</th>
                <th>Sweep Group</th>
                <th>Started</th>
                <th>Duration</th>
                <th>Hosts</th>
                <th>Success Rate</th>
                <th>Metrics</th>
              </tr>
            </thead>
            <tbody>
              <%= for execution <- @recent do %>
                <.recent_execution_row
                  execution={execution}
                  group={Map.get(@groups_map, execution.sweep_group_id)}
                />
              <% end %>
            </tbody>
          </table>
        </div>
      </.ui_panel>
    </div>
    """
  end

  # Statistics Cards Component
  attr :running, :list, required: true
  attr :recent, :list, required: true

  defp scan_statistics(assigns) do
    # Calculate stats from recent executions
    completed_recent = Enum.filter(assigns.recent, &(&1.status == :completed))

    total_hosts = Enum.reduce(completed_recent, 0, fn e, acc -> acc + (e.hosts_total || 0) end)

    available_hosts =
      Enum.reduce(completed_recent, 0, fn e, acc -> acc + (e.hosts_available || 0) end)

    avg_success_rate = average_success_rate(completed_recent)

    failed_count = Enum.count(assigns.recent, &(&1.status == :failed))

    # Aggregate scanner metrics from recent completions
    aggregate_metrics = aggregate_scanner_metrics(completed_recent)

    assigns =
      assigns
      |> assign(:total_hosts, total_hosts)
      |> assign(:available_hosts, available_hosts)
      |> assign(:avg_success_rate, avg_success_rate)
      |> assign(:failed_count, failed_count)
      |> assign(:completed_count, length(completed_recent))
      |> assign(:aggregate_metrics, aggregate_metrics)

    ~H"""
    <div class="space-y-4">
      <!-- Main Stats -->
      <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div class="bg-base-200/50 rounded-lg p-4">
          <div class="text-xs text-base-content/60 uppercase tracking-wide">Running</div>
          <div class="text-2xl font-bold mt-1 flex items-center gap-2">
            {length(@running)}
            <span :if={length(@running) > 0} class="size-2 rounded-full bg-success animate-pulse">
            </span>
          </div>
        </div>
        <div class="bg-base-200/50 rounded-lg p-4">
          <div class="text-xs text-base-content/60 uppercase tracking-wide">Hosts Scanned</div>
          <div class="text-2xl font-bold mt-1">{@total_hosts}</div>
          <div class="text-xs text-base-content/60">{@available_hosts} available</div>
        </div>
        <div class="bg-base-200/50 rounded-lg p-4">
          <div class="text-xs text-base-content/60 uppercase tracking-wide">Avg Success Rate</div>
          <div class={"text-2xl font-bold mt-1 #{success_rate_color(@avg_success_rate)}"}>
            {@avg_success_rate}%
          </div>
        </div>
        <div class="bg-base-200/50 rounded-lg p-4">
          <div class="text-xs text-base-content/60 uppercase tracking-wide">Recent Executions</div>
          <div class="text-2xl font-bold mt-1">{@completed_count}</div>
          <div :if={@failed_count > 0} class="text-xs text-error">{@failed_count} failed</div>
        </div>
      </div>
      
    <!-- Scanner Metrics Summary (only if we have metrics) -->
      <div :if={@aggregate_metrics.has_data} class="bg-base-200/30 rounded-lg p-4">
        <div class="flex items-center gap-2 mb-3">
          <.icon name="hero-chart-bar" class="size-4 text-base-content/60" />
          <span class="text-xs text-base-content/60 uppercase tracking-wide">
            Scanner Performance (Recent Scans)
          </span>
        </div>
        <div class="grid grid-cols-2 md:grid-cols-5 gap-4 text-sm">
          <div>
            <div class="text-base-content/60 text-xs">Packets Sent</div>
            <div class="font-semibold font-mono">
              {format_number(@aggregate_metrics.packets_sent)}
            </div>
          </div>
          <div>
            <div class="text-base-content/60 text-xs">Packets Received</div>
            <div class="font-semibold font-mono">
              {format_number(@aggregate_metrics.packets_recv)}
            </div>
          </div>
          <div>
            <div class="text-base-content/60 text-xs">Avg Drop Rate</div>
            <div class={"font-semibold font-mono #{if @aggregate_metrics.avg_drop_rate > 1.0, do: "text-warning", else: ""}"}>
              {Float.round(@aggregate_metrics.avg_drop_rate, 2)}%
            </div>
          </div>
          <div>
            <div class="text-base-content/60 text-xs">Total Retries</div>
            <div class="font-semibold font-mono">
              {format_number(@aggregate_metrics.retries_successful)}/{format_number(
                @aggregate_metrics.retries_attempted
              )}
            </div>
          </div>
          <div>
            <div class="text-base-content/60 text-xs">Rate Deferrals</div>
            <div class={"font-semibold font-mono #{if @aggregate_metrics.rate_limit_deferrals > 0, do: "text-info", else: ""}"}>
              {format_number(@aggregate_metrics.rate_limit_deferrals)}
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp average_success_rate([]), do: 0.0

  defp average_success_rate(executions) do
    executions
    |> Enum.map(&execution_success_rate/1)
    |> Enum.sum()
    |> Kernel./(length(executions))
    |> Float.round(1)
  end

  defp execution_success_rate(execution) do
    case execution.hosts_total do
      total when is_integer(total) and total > 0 ->
        (execution.hosts_available || 0) / total * 100

      _ ->
        0
    end
  end

  defp aggregate_scanner_metrics(executions) do
    executions_with_metrics =
      Enum.filter(executions, fn e ->
        e.scanner_metrics && e.scanner_metrics != %{}
      end)

    if Enum.empty?(executions_with_metrics) do
      %{has_data: false}
    else
      packets_sent =
        Enum.reduce(executions_with_metrics, 0, fn e, acc ->
          acc + (get_in(e.scanner_metrics, ["packets_sent"]) || 0)
        end)

      packets_recv =
        Enum.reduce(executions_with_metrics, 0, fn e, acc ->
          acc + (get_in(e.scanner_metrics, ["packets_recv"]) || 0)
        end)

      retries_attempted =
        Enum.reduce(executions_with_metrics, 0, fn e, acc ->
          acc + (get_in(e.scanner_metrics, ["retries_attempted"]) || 0)
        end)

      retries_successful =
        Enum.reduce(executions_with_metrics, 0, fn e, acc ->
          acc + (get_in(e.scanner_metrics, ["retries_successful"]) || 0)
        end)

      rate_limit_deferrals =
        Enum.reduce(executions_with_metrics, 0, fn e, acc ->
          acc + (get_in(e.scanner_metrics, ["rate_limit_deferrals"]) || 0)
        end)

      # Calculate average drop rate
      drop_rates =
        executions_with_metrics
        |> Enum.map(fn e -> get_in(e.scanner_metrics, ["rx_drop_rate_percent"]) || 0.0 end)

      avg_drop_rate =
        if Enum.empty?(drop_rates) do
          0.0
        else
          Enum.sum(drop_rates) / length(drop_rates)
        end

      %{
        has_data: true,
        packets_sent: packets_sent,
        packets_recv: packets_recv,
        retries_attempted: retries_attempted,
        retries_successful: retries_successful,
        rate_limit_deferrals: rate_limit_deferrals,
        avg_drop_rate: avg_drop_rate
      }
    end
  end

  # Running Scan Card Component
  attr :execution, :map, required: true
  attr :group, :map, default: nil
  attr :progress, :map, default: nil

  defp running_scan_card(assigns) do
    # Calculate elapsed time
    elapsed_ms =
      if assigns.execution.started_at do
        DateTime.diff(DateTime.utc_now(), assigns.execution.started_at, :millisecond)
      else
        0
      end

    # Use real-time progress if available, otherwise fall back to execution data
    progress = assigns.progress

    hosts_processed =
      if progress, do: progress.hosts_processed, else: assigns.execution.hosts_total || 0

    hosts_available =
      if progress, do: progress.hosts_available, else: assigns.execution.hosts_available || 0

    hosts_failed =
      if progress, do: progress.hosts_failed, else: assigns.execution.hosts_failed || 0

    batch_info =
      if progress && progress.total_batches,
        do: "Batch #{progress.batch_num}/#{progress.total_batches}",
        else: nil

    assigns =
      assigns
      |> assign(:elapsed_ms, elapsed_ms)
      |> assign(:hosts_processed, hosts_processed)
      |> assign(:hosts_available, hosts_available)
      |> assign(:hosts_failed, hosts_failed)
      |> assign(:batch_info, batch_info)
      |> assign(:has_progress, progress != nil)

    ~H"""
    <div class="bg-base-200/30 rounded-lg p-4 border border-base-200">
      <div class="flex items-start justify-between">
        <div class="flex items-center gap-3">
          <div class="relative">
            <span class="loading loading-spinner loading-sm text-success"></span>
          </div>
          <div>
            <div class="font-medium">
              {if @group, do: @group.name, else: "Unknown Group"}
            </div>
            <div class="text-xs text-base-content/60 flex items-center gap-2">
              <span :if={@execution.agent_id}>
                <.icon name="hero-server" class="size-3 inline" />
                {@execution.agent_id}
              </span>
              <span>Started {format_relative_time(@execution.started_at)}</span>
            </div>
          </div>
        </div>
        <div class="text-right">
          <div class="text-sm font-mono">{format_duration(@elapsed_ms)}</div>
          <div class="text-xs text-base-content/60">
            <span class="text-success">{@hosts_available}</span>
            <span :if={@hosts_failed > 0} class="text-error ml-1">/ {@hosts_failed} failed</span>
            <span> of     {@hosts_processed} hosts</span>
          </div>
          <div :if={@batch_info} class="text-xs text-base-content/40 mt-0.5">
            {@batch_info}
          </div>
        </div>
      </div>
      
    <!-- Progress bar with real-time updates -->
      <div class="mt-3">
        <div class="h-1.5 bg-base-300 rounded-full overflow-hidden">
          <div
            class="h-full bg-success transition-all duration-300"
            style={"width: #{batch_progress_percent(@progress)}%"}
          >
          </div>
        </div>
        <div
          :if={@has_progress && @progress.total_batches}
          class="flex justify-between text-xs text-base-content/40 mt-1"
        >
          <span>Processing...</span>
          <span>{batch_progress_percent(@progress)}%</span>
        </div>
      </div>
    </div>
    """
  end

  # Recent Execution Row Component
  attr :execution, :map, required: true
  attr :group, :map, default: nil

  defp recent_execution_row(assigns) do
    has_metrics = assigns.execution.scanner_metrics && assigns.execution.scanner_metrics != %{}
    assigns = assign(assigns, :has_metrics, has_metrics)

    ~H"""
    <tr class="hover:bg-base-200/40">
      <td>
        <.execution_status_badge status={@execution.status} />
      </td>
      <td>
        <div class="font-medium">
          {if @group, do: @group.name, else: "Unknown Group"}
        </div>
        <div :if={@execution.agent_id} class="text-xs text-base-content/60">
          {@execution.agent_id}
        </div>
      </td>
      <td class="text-xs text-base-content/60">
        {format_relative_time(@execution.started_at)}
      </td>
      <td class="font-mono text-xs">
        {format_duration(@execution.duration_ms)}
      </td>
      <td class="text-xs">
        <span :if={@execution.hosts_total}>
          {@execution.hosts_available || 0} / {@execution.hosts_total}
        </span>
        <span :if={!@execution.hosts_total} class="text-base-content/40">—</span>
      </td>
      <td>
        <.success_rate_badge execution={@execution} />
      </td>
      <td>
        <div :if={@has_metrics} class="dropdown dropdown-end">
          <div tabindex="0" role="button" class="btn btn-ghost btn-xs">
            <.icon name="hero-chart-bar" class="size-4" />
          </div>
          <div
            tabindex="0"
            class="dropdown-content z-[1] card card-compact w-80 p-2 shadow bg-base-100 border border-base-200"
          >
            <div class="card-body p-2">
              <h3 class="text-sm font-semibold mb-2">Scanner Metrics</h3>
              <.scanner_metrics_grid metrics={@execution.scanner_metrics} />
            </div>
          </div>
        </div>
        <span :if={!@has_metrics} class="text-base-content/40 text-xs">—</span>
      </td>
    </tr>
    """
  end

  # Scanner Metrics Grid Component
  attr :metrics, :map, required: true

  defp scanner_metrics_grid(assigns) do
    metrics = assigns.metrics || %{}

    assigns =
      assigns
      |> assign(:packets_sent, Map.get(metrics, "packets_sent", 0))
      |> assign(:packets_recv, Map.get(metrics, "packets_recv", 0))
      |> assign(:packets_dropped, Map.get(metrics, "packets_dropped", 0))
      |> assign(:retries_attempted, Map.get(metrics, "retries_attempted", 0))
      |> assign(:retries_successful, Map.get(metrics, "retries_successful", 0))
      |> assign(:rate_limit_deferrals, Map.get(metrics, "rate_limit_deferrals", 0))
      |> assign(:rx_drop_rate_percent, Map.get(metrics, "rx_drop_rate_percent", 0.0))
      |> assign(:port_exhaustion_count, Map.get(metrics, "port_exhaustion_count", 0))

    ~H"""
    <div class="grid grid-cols-2 gap-2 text-xs">
      <div class="bg-base-200/50 rounded p-2">
        <div class="text-base-content/60">Packets Sent</div>
        <div class="font-semibold font-mono">{format_number(@packets_sent)}</div>
      </div>
      <div class="bg-base-200/50 rounded p-2">
        <div class="text-base-content/60">Packets Received</div>
        <div class="font-semibold font-mono">{format_number(@packets_recv)}</div>
      </div>
      <div class="bg-base-200/50 rounded p-2">
        <div class="text-base-content/60">Packets Dropped</div>
        <div class={"font-semibold font-mono #{if @packets_dropped > 0, do: "text-warning", else: ""}"}>
          {format_number(@packets_dropped)}
        </div>
      </div>
      <div class="bg-base-200/50 rounded p-2">
        <div class="text-base-content/60">RX Drop Rate</div>
        <div class={"font-semibold font-mono #{if @rx_drop_rate_percent > 1.0, do: "text-warning", else: ""}"}>
          {Float.round(@rx_drop_rate_percent || 0.0, 2)}%
        </div>
      </div>
      <div class="bg-base-200/50 rounded p-2">
        <div class="text-base-content/60">Retries</div>
        <div class="font-semibold font-mono">
          {format_number(@retries_successful)}/{format_number(@retries_attempted)}
        </div>
      </div>
      <div class="bg-base-200/50 rounded p-2">
        <div class="text-base-content/60">Rate Limit Deferrals</div>
        <div class={"font-semibold font-mono #{if @rate_limit_deferrals > 0, do: "text-info", else: ""}"}>
          {format_number(@rate_limit_deferrals)}
        </div>
      </div>
      <div :if={@port_exhaustion_count > 0} class="col-span-2 bg-error/10 rounded p-2">
        <div class="text-error/80">Port Exhaustion Events</div>
        <div class="font-semibold font-mono text-error">{format_number(@port_exhaustion_count)}</div>
      </div>
    </div>
    """
  end

  defp format_number(nil), do: "0"
  defp format_number(n) when is_float(n), do: Float.round(n, 2) |> to_string()

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}/, "\\0,")
    |> String.reverse()
    |> String.trim_leading(",")
  end

  defp format_number(n), do: to_string(n)

  # Execution Status Badge
  attr :status, :atom, required: true

  defp execution_status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium",
      status_badge_class(@status)
    ]}>
      <.icon name={status_icon(@status)} class="size-3" />
      {status_label(@status)}
    </span>
    """
  end

  # Success Rate Badge
  attr :execution, :map, required: true

  defp success_rate_badge(assigns) do
    rate =
      if assigns.execution.hosts_total && assigns.execution.hosts_total > 0 do
        ((assigns.execution.hosts_available || 0) / assigns.execution.hosts_total * 100)
        |> Float.round(1)
      else
        nil
      end

    assigns = assign(assigns, :rate, rate)

    ~H"""
    <span :if={@rate} class={"text-xs font-medium #{success_rate_color(@rate)}"}>
      {@rate}%
    </span>
    <span :if={!@rate} class="text-xs text-base-content/40">—</span>
    """
  end

  # Helper functions for Active Scans panel

  defp status_badge_class(:completed), do: "bg-success/20 text-success"
  defp status_badge_class(:failed), do: "bg-error/20 text-error"
  defp status_badge_class(:running), do: "bg-info/20 text-info"
  defp status_badge_class(_), do: "bg-base-200 text-base-content/60"

  defp status_icon(:completed), do: "hero-check-circle"
  defp status_icon(:failed), do: "hero-x-circle"
  defp status_icon(:running), do: "hero-arrow-path"
  defp status_icon(_), do: "hero-clock"

  defp status_label(:completed), do: "Completed"
  defp status_label(:failed), do: "Failed"
  defp status_label(:running), do: "Running"
  defp status_label(:pending), do: "Pending"
  defp status_label(_), do: "Unknown"

  defp success_rate_color(rate) when rate >= 90, do: "text-success"
  defp success_rate_color(rate) when rate >= 70, do: "text-warning"
  defp success_rate_color(_rate), do: "text-error"

  # Calculate progress percentage from batch info
  defp batch_progress_percent(%{batch_num: batch_num, total_batches: total_batches})
       when is_integer(batch_num) and is_integer(total_batches) and total_batches > 0 do
    Float.round(batch_num / total_batches * 100, 1)
  end

  defp batch_progress_percent(_), do: 0

  defp format_relative_time(nil), do: "—"

  defp format_relative_time(%DateTime{} = dt) do
    diff_seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff_seconds < 60 -> "#{diff_seconds}s ago"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)}h ago"
      true -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
    end
  end

  defp format_relative_time(_), do: "—"

  defp format_duration(nil), do: "—"
  defp format_duration(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"

  defp format_duration(ms) when is_integer(ms) and ms < 60_000,
    do: "#{Float.round(ms / 1000, 1)}s"

  defp format_duration(ms) when is_integer(ms) do
    minutes = div(ms, 60_000)
    seconds = div(rem(ms, 60_000), 1000)
    "#{minutes}m #{seconds}s"
  end

  defp format_duration(_), do: "—"

  # Group Form
  attr :form, :any, required: true
  attr :show_form, :atom, required: true
  attr :profiles, :list, required: true
  attr :criteria_rules, :list, default: []
  attr :target_count, :integer, default: nil

  defp group_form(assigns) do
    assigns = assign(assigns, :criteria_fields, @criteria_fields)

    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center justify-between w-full">
          <div class="text-sm font-semibold">
            {if @show_form == :new_group, do: "New Sweep Group", else: "Edit Sweep Group"}
          </div>
          <.link navigate={~p"/settings/networks"}>
            <.ui_button variant="ghost" size="sm">Cancel</.ui_button>
          </.link>
        </div>
      </:header>

      <.form for={@form} phx-submit="save_group" phx-change="validate_group" class="space-y-6">
        <!-- Basic Info Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold text-base-content/80 uppercase tracking-wide">
            Basic Information
          </h3>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="label">
                <span class="label-text">Name</span>
              </label>
              <.input type="text" field={@form[:name]} class="input input-bordered w-full" required />
            </div>
            <div>
              <label class="label">
                <span class="label-text">Partition</span>
              </label>
              <.input
                type="text"
                field={@form[:partition]}
                class="input input-bordered w-full"
                placeholder="default"
              />
            </div>
          </div>

          <div>
            <label class="label">
              <span class="label-text">Description</span>
            </label>
            <.input
              type="textarea"
              field={@form[:description]}
              class="textarea textarea-bordered w-full"
              rows="2"
            />
          </div>
        </div>
        
    <!-- Schedule Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold text-base-content/80 uppercase tracking-wide">Schedule</h3>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="label">
                <span class="label-text">Scan Interval</span>
              </label>
              <.input
                type="select"
                field={@form[:interval]}
                class="select select-bordered w-full"
                options={[
                  {"5 minutes", "5m"},
                  {"15 minutes", "15m"},
                  {"30 minutes", "30m"},
                  {"1 hour", "1h"},
                  {"2 hours", "2h"},
                  {"6 hours", "6h"},
                  {"12 hours", "12h"},
                  {"24 hours", "24h"}
                ]}
              />
            </div>
            <div>
              <label class="label">
                <span class="label-text">Scanner Profile</span>
              </label>
              <.input
                type="select"
                field={@form[:profile_id]}
                class="select select-bordered w-full"
                options={[{"Default settings", ""} | Enum.map(@profiles, &{&1.name, &1.id})]}
              />
            </div>
          </div>
        </div>
        
    <!-- Target Criteria Section -->
        <div class="space-y-4">
          <div class="flex flex-col gap-2 md:flex-row md:items-end md:justify-between">
            <div>
              <h3 class="text-sm font-semibold text-base-content/80 uppercase tracking-wide">
                Targeting Rules
              </h3>
              <p class="text-xs text-base-content/60">
                Build rules similar to the SRQL query builder. All rules must match (AND).
              </p>
            </div>
          </div>

          <div :if={@target_count != nil} class="flex items-center gap-2">
            <span class="text-sm text-base-content/60">
              <span class="font-semibold text-primary">{@target_count}</span> device(s) match
            </span>
          </div>

          <div class="space-y-2">
            <%= for rule <- @criteria_rules do %>
              <.criteria_rule_row rule={rule} fields={@criteria_fields} />
            <% end %>

            <button
              type="button"
              phx-click="add_criteria_rule"
              class="btn btn-ghost btn-sm gap-1 text-primary"
            >
              <.icon name="hero-plus" class="size-4" /> Add Tag
            </button>
          </div>
        </div>
        
    <!-- Static Targets Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold text-base-content/80 uppercase tracking-wide">
            Static Targets
          </h3>
          <p class="text-xs text-base-content/60">
            IPs, CIDRs, or ranges to always include, regardless of tags.
          </p>
          <.input
            type="textarea"
            field={@form[:static_targets]}
            value={format_static_targets(@form[:static_targets].value)}
            class="textarea textarea-bordered w-full font-mono text-sm"
            rows="3"
            placeholder="10.0.1.0/24&#10;192.168.1.0/24&#10;10.0.0.10-10.0.0.50"
          />
        </div>
        
    <!-- Enable Toggle -->
        <div class="flex items-center gap-2 pt-2">
          <.input type="checkbox" field={@form[:enabled]} class="checkbox checkbox-primary" />
          <label class="label-text">Enable this sweep group</label>
        </div>
        
    <!-- Actions -->
        <div class="flex justify-end gap-2 pt-4 border-t border-base-200">
          <.link navigate={~p"/settings/networks"}>
            <.ui_button variant="ghost">Cancel</.ui_button>
          </.link>
          <.ui_button type="submit" variant="primary">Save Sweep Group</.ui_button>
        </div>
      </.form>
    </.ui_panel>
    """
  end

  # Criteria Rule Row Component
  attr :rule, :map, required: true
  attr :fields, :list, required: true

  defp criteria_rule_row(assigns) do
    ~H"""
    <div class="flex items-center gap-3">
      <.query_builder_pill label="Rule">
        <.ui_inline_select
          name="field"
          class="text-sm font-medium"
          phx-change="update_criteria_rule"
          phx-value-id={@rule.id}
        >
          <%= if @rule.field && not field_known?(@rule.field) do %>
            <option value={@rule.field} selected>{@rule.field}</option>
          <% end %>
          <%= for {label, field} <- @fields do %>
            <option value={field} selected={@rule.field == field}>{label}</option>
          <% end %>
        </.ui_inline_select>

        <.ui_inline_select
          name="operator"
          class="text-xs text-base-content/70 font-medium"
          phx-change="update_criteria_rule"
          phx-value-id={@rule.id}
        >
          <%= if @rule.operator && not operator_known?(@rule.field, @rule.operator) do %>
            <option value={@rule.operator} selected>{@rule.operator}</option>
          <% end %>
          <%= for {label, value} <- operators_for_field(@rule.field) do %>
            <option value={value} selected={@rule.operator == value}>{label}</option>
          <% end %>
        </.ui_inline_select>

        <%= if boolean_field?(@rule.field) do %>
          <.ui_inline_select
            name="value"
            class="text-xs text-base-content/70 font-medium"
            phx-change="update_criteria_rule"
            phx-value-id={@rule.id}
          >
            <option value="true" selected={to_string(@rule.value) == "true"}>true</option>
            <option value="false" selected={to_string(@rule.value) == "false"}>false</option>
          </.ui_inline_select>
        <% else %>
          <.ui_inline_input
            type="text"
            name="value"
            value={to_string(@rule.value || "")}
            placeholder={value_placeholder(@rule.field, @rule.operator)}
            class="placeholder:text-base-content/40 w-56"
            phx-change="update_criteria_rule"
            phx-debounce="300"
            phx-value-id={@rule.id}
          />
        <% end %>
      </.query_builder_pill>
      
    <!-- Remove Button -->
      <button
        type="button"
        phx-click="remove_criteria_rule"
        phx-value-id={@rule.id}
        class="btn btn-ghost btn-sm btn-square text-error/70 hover:text-error"
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </div>
    """
  end

  # Profile Form
  attr :form, :any, required: true
  attr :show_form, :atom, required: true

  defp profile_form(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center justify-between w-full">
          <div class="text-sm font-semibold">
            {if @show_form == :new_profile, do: "New Scanner Profile", else: "Edit Scanner Profile"}
          </div>
          <.link navigate={~p"/settings/networks"}>
            <.ui_button variant="ghost" size="sm">Cancel</.ui_button>
          </.link>
        </div>
      </:header>

      <.form for={@form} phx-submit="save_profile" phx-change="validate_profile" class="space-y-4">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div>
            <label class="label">
              <span class="label-text">Name</span>
            </label>
            <.input type="text" field={@form[:name]} class="input input-bordered w-full" required />
          </div>
          <div>
            <label class="label">
              <span class="label-text">Timeout</span>
            </label>
            <.input
              type="select"
              field={@form[:timeout]}
              class="select select-bordered w-full"
              options={[
                {"1 second", "1s"},
                {"3 seconds", "3s"},
                {"5 seconds", "5s"},
                {"10 seconds", "10s"},
                {"30 seconds", "30s"}
              ]}
            />
          </div>
        </div>

        <div>
          <label class="label">
            <span class="label-text">Description</span>
          </label>
          <.input
            type="textarea"
            field={@form[:description]}
            class="textarea textarea-bordered w-full"
            rows="2"
          />
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div>
            <label class="label">
              <span class="label-text">Ports (comma-separated)</span>
            </label>
            <.input
              type="text"
              field={@form[:ports]}
              class="input input-bordered w-full font-mono"
              placeholder="22, 80, 443, 3389, 8080"
            />
          </div>
          <div>
            <label class="label">
              <span class="label-text">Concurrency</span>
            </label>
            <.input
              type="number"
              field={@form[:concurrency]}
              class="input input-bordered w-full"
              min="1"
              max="500"
            />
          </div>
        </div>

        <div>
          <label class="label">
            <span class="label-text">Sweep Modes</span>
          </label>
          <div class="flex flex-wrap gap-4">
            <label class="flex items-center gap-2 cursor-pointer">
              <input type="checkbox" name="form[sweep_modes][]" value="icmp" class="checkbox" checked />
              <span>ICMP (Ping)</span>
            </label>
            <label class="flex items-center gap-2 cursor-pointer">
              <input type="checkbox" name="form[sweep_modes][]" value="tcp" class="checkbox" checked />
              <span>TCP</span>
            </label>
            <label class="flex items-center gap-2 cursor-pointer">
              <input type="checkbox" name="form[sweep_modes][]" value="arp" class="checkbox" />
              <span>ARP</span>
            </label>
          </div>
        </div>

        <div class="flex items-center gap-2">
          <.input type="checkbox" field={@form[:enabled]} class="checkbox checkbox-primary" />
          <label class="label-text">Enabled</label>
        </div>

        <div class="flex justify-end gap-2 pt-4">
          <.link navigate={~p"/settings/networks"}>
            <.ui_button variant="ghost">Cancel</.ui_button>
          </.link>
          <.ui_button type="submit" variant="primary">Save Profile</.ui_button>
        </div>
      </.form>
    </.ui_panel>
    """
  end

  # Group Detail View
  attr :group, :map, required: true

  defp group_detail(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <.link navigate={~p"/settings/networks"}>
            <.ui_button variant="ghost" size="sm">
              <.icon name="hero-arrow-left" class="size-4" />
            </.ui_button>
          </.link>
          <div>
            <h2 class="text-xl font-semibold">{@group.name}</h2>
            <p :if={@group.description} class="text-sm text-base-content/60">{@group.description}</p>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <.link navigate={~p"/settings/networks/groups/#{@group.id}/edit"}>
            <.ui_button variant="outline" size="sm">
              <.icon name="hero-pencil" class="size-4" /> Edit
            </.ui_button>
          </.link>
        </div>
      </div>

      <.ui_panel>
        <:header>
          <div class="text-sm font-semibold">Configuration</div>
        </:header>

        <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
          <div>
            <div class="text-xs text-base-content/60 uppercase">Status</div>
            <div class="flex items-center gap-1.5 mt-1">
              <span class={"size-2 rounded-full #{if @group.enabled, do: "bg-success", else: "bg-base-content/30"}"}>
              </span>
              <span>{if @group.enabled, do: "Enabled", else: "Disabled"}</span>
            </div>
          </div>
          <div>
            <div class="text-xs text-base-content/60 uppercase">Schedule</div>
            <div class="mt-1 font-mono">{format_schedule(@group)}</div>
          </div>
          <div>
            <div class="text-xs text-base-content/60 uppercase">Partition</div>
            <div class="mt-1">{@group.partition}</div>
          </div>
          <div>
            <div class="text-xs text-base-content/60 uppercase">Last Run</div>
            <div class="mt-1">{format_last_run(@group.last_run_at)}</div>
          </div>
        </div>
      </.ui_panel>

      <.ui_panel>
        <:header>
          <div class="text-sm font-semibold">Targets</div>
        </:header>

        <div class="space-y-2">
          <div :if={@group.static_targets != []} class="space-y-1">
            <div class="text-xs text-base-content/60 uppercase">Static Targets</div>
            <div class="flex flex-wrap gap-2">
              <%= for target <- (@group.static_targets || []) do %>
                <.ui_badge variant="ghost" size="sm" class="font-mono">{target}</.ui_badge>
              <% end %>
            </div>
          </div>
          <div :if={@group.target_criteria != %{} and @group.target_criteria != nil} class="space-y-2">
            <div class="text-xs text-base-content/60 uppercase">Targeting Rules</div>
            <div class="space-y-1">
              <%= for {field, spec} <- @group.target_criteria || %{} do %>
                <.criteria_display_row field={field} spec={spec} />
              <% end %>
            </div>
          </div>
          <div :if={@group.static_targets == [] and @group.target_criteria == %{}}>
            <p class="text-base-content/60">No targets configured.</p>
          </div>
        </div>
      </.ui_panel>
    </div>
    """
  end

  # Helpers

  defp load_sweep_groups(scope) do
    case Ash.read(SweepGroup, scope: scope) do
      {:ok, groups} -> groups
      {:error, _} -> []
    end
  end

  defp load_sweep_group(scope, id) do
    case Ash.get(SweepGroup, id, scope: scope) do
      {:ok, group} -> group
      {:error, _} -> nil
    end
  end

  defp load_sweep_profiles(scope) do
    case Ash.read(SweepProfile, scope: scope) do
      {:ok, profiles} -> profiles
      {:error, _} -> []
    end
  end

  defp load_sweep_profile(scope, id) do
    case Ash.get(SweepProfile, id, scope: scope) do
      {:ok, profile} -> profile
      {:error, _} -> nil
    end
  end

  defp load_running_executions(scope) do
    case Ash.read(SweepGroupExecution, action: :running, scope: scope) do
      {:ok, executions} -> executions
      {:error, _} -> []
    end
  end

  defp load_recent_executions(scope) do
    case Ash.read(SweepGroupExecution,
           action: :recent,
           scope: scope
         ) do
      {:ok, executions} ->
        # Filter out running ones (they appear in the running section)
        Enum.reject(executions, &(&1.status == :running))

      {:error, _} ->
        []
    end
  end

  defp format_schedule(group) do
    case group.schedule_type do
      :cron -> group.cron_expression || "—"
      _ -> "Every #{group.interval}"
    end
  end

  defp format_last_run(nil), do: "Never"

  defp format_last_run(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_last_run(_), do: "—"

  defp format_ports([]), do: "—"
  defp format_ports(ports) when length(ports) <= 5, do: Enum.join(ports, ", ")
  defp format_ports(ports), do: "#{length(ports)} ports"

  defp default_criteria_field, do: "hostname"

  defp default_operator_for(field) do
    case field do
      "tags" -> "has_any"
      "discovery_sources" -> "contains"
      "ip" -> "eq"
      "is_available" -> "eq"
      field when field in @numeric_fields -> "eq"
      _ -> "contains"
    end
  end

  defp ensure_operator_for_field(field, operator) do
    operators =
      operators_for_field(field)
      |> Enum.map(fn {_label, value} -> value end)

    if operator in operators do
      operator
    else
      default_operator_for(field)
    end
  end

  defp operators_for_field(field) do
    case field do
      "tags" -> @tag_operators
      "discovery_sources" -> @discovery_operators
      "ip" -> @ip_operators
      field when field in @boolean_fields -> @boolean_operators
      field when field in @numeric_fields -> @numeric_operators
      _ -> @text_operators
    end
  end

  defp field_known?(field) do
    Enum.any?(@criteria_fields, fn {_label, value} -> value == field end)
  end

  defp operator_known?(field, operator) do
    operators_for_field(field)
    |> Enum.any?(fn {_label, value} -> value == operator end)
  end

  defp boolean_field?(field), do: field in @boolean_fields

  defp value_placeholder(field, operator) do
    cond do
      operator in @list_operators -> "value1, value2"
      field == "discovery_sources" -> "sweep, sync, snmp"
      field == "tags" -> "env=prod, critical"
      field == "ip" and operator in ["in_cidr", "not_in_cidr"] -> "10.0.0.0/24"
      field == "ip" and operator == "in_range" -> "10.0.0.10-10.0.0.50"
      true -> "value"
    end
  end

  defp rule_active?(rule) do
    case normalize_rule_value(rule.field, rule.operator, rule.value) do
      {:ok, _} -> true
      :skip -> false
    end
  end

  defp normalize_rule_value(field, operator, value) do
    field = field || default_criteria_field()
    operator = operator || default_operator_for(field)
    value = to_string(value || "") |> String.trim()

    cond do
      operator in @list_operators ->
        list = parse_list(value)
        if list == [], do: :skip, else: {:ok, list}

      value == "" ->
        :skip

      field in @boolean_fields ->
        parse_boolean(value)

      operator in ["gt", "gte", "lt", "lte"] ->
        parse_number(value)

      true ->
        {:ok, value}
    end
  end

  defp parse_list(value) do
    value
    |> String.split(~r/[\n,]+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_boolean(value) do
    case String.downcase(value) do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      "yes" -> {:ok, true}
      "no" -> {:ok, false}
      "1" -> {:ok, true}
      "0" -> {:ok, false}
      _ -> :skip
    end
  end

  defp parse_number(value) do
    case Integer.parse(value) do
      {int, ""} ->
        {:ok, int}

      _ ->
        case Float.parse(value) do
          {float, ""} -> {:ok, float}
          _ -> :skip
        end
    end
  end

  defp format_rule_value(operator, value) when operator in @list_operators and is_list(value) do
    Enum.map_join(value, ", ", &to_string/1)
  end

  defp format_rule_value(_operator, value), do: to_string(value)

  defp format_static_targets(targets) when is_list(targets) do
    Enum.join(targets, "\n")
  end

  defp format_static_targets(targets) when is_binary(targets), do: targets
  defp format_static_targets(_), do: ""

  # Criteria Display Component (for group detail view)
  attr :field, :string, required: true
  attr :spec, :map, required: true

  defp criteria_display_row(assigns) do
    {operator, value} =
      case Map.to_list(assigns.spec) do
        [{op, val}] -> {op, val}
        _ -> {"unknown", ""}
      end

    field_label = get_field_label(assigns.field)
    operator_label = get_operator_label(operator)

    assigns =
      assigns
      |> assign(:field_label, field_label)
      |> assign(:operator_label, operator_label)
      |> assign(:display_value, format_criteria_value(value))

    ~H"""
    <div class="flex items-center gap-2 p-2 bg-base-200/50 rounded text-sm">
      <span class="font-medium">{@field_label}</span>
      <span class="text-base-content/60">{@operator_label}</span>
      <span class="font-mono text-primary">{@display_value}</span>
    </div>
    """
  end

  defp get_field_label(field) do
    label =
      @criteria_fields
      |> Enum.find_value(fn {display, value} ->
        if value == field, do: display, else: nil
      end)

    label || String.capitalize(field)
  end

  defp get_operator_label("has_any"), do: "matches any"
  defp get_operator_label("has_all"), do: "matches all"
  defp get_operator_label("eq"), do: "equals"
  defp get_operator_label("neq"), do: "not equals"
  defp get_operator_label("in"), do: "in"
  defp get_operator_label("not_in"), do: "not in"
  defp get_operator_label("contains"), do: "contains"
  defp get_operator_label("not_contains"), do: "does not contain"
  defp get_operator_label("starts_with"), do: "starts with"
  defp get_operator_label("ends_with"), do: "ends with"
  defp get_operator_label("in_cidr"), do: "in range"
  defp get_operator_label("not_in_cidr"), do: "not in range"
  defp get_operator_label("gt"), do: ">"
  defp get_operator_label("gte"), do: ">="
  defp get_operator_label("lt"), do: "<"
  defp get_operator_label("lte"), do: "<="
  defp get_operator_label("is_null"), do: "is empty"
  defp get_operator_label("is_not_null"), do: "is not empty"
  defp get_operator_label(op), do: op

  defp format_criteria_value(value) when is_list(value), do: Enum.join(value, ", ")
  defp format_criteria_value(true), do: "yes"
  defp format_criteria_value(false), do: "no"
  defp format_criteria_value(value), do: to_string(value)

  # Rules <-> Criteria conversion helpers

  defp rules_to_criteria(rules) when is_list(rules) do
    Enum.reduce(rules, %{}, fn rule, acc ->
      field = rule.field || default_criteria_field()
      operator = rule.operator || default_operator_for(field)

      case normalize_rule_value(field, operator, rule.value) do
        :skip -> acc
        {:ok, value} -> merge_rule_criteria(acc, field, operator, value)
      end
    end)
  end

  defp merge_rule_criteria(acc, "tags" = field, operator, value) when is_list(value) do
    case Map.get(acc, field) do
      %{^operator => existing} when is_list(existing) ->
        Map.put(acc, field, %{operator => Enum.uniq(existing ++ value)})

      _ ->
        Map.put(acc, field, %{operator => value})
    end
  end

  defp merge_rule_criteria(acc, field, operator, value) do
    Map.put(acc, field, %{operator => value})
  end

  defp criteria_to_rules(criteria) when criteria == %{} or criteria == nil, do: []

  defp criteria_to_rules(criteria) when is_map(criteria) do
    Enum.flat_map(criteria, fn {field, operator_spec} ->
      case Map.to_list(operator_spec) do
        [{operator, value}] ->
          [
            %{
              id: System.unique_integer([:positive]),
              field: field,
              operator: operator,
              value: format_rule_value(operator, value)
            }
          ]

        _ ->
          []
      end
    end)
  end

  # Device count query using SRQL
  defp get_matching_device_count(scope, criteria) do
    srql_query = criteria_to_srql_query(criteria)

    if srql_query == "" do
      nil
    else
      srql_module =
        Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)

      full_query = "in:devices #{srql_query} limit:10000"

      case srql_module.query(full_query, %{scope: scope}) do
        {:ok, %{"results" => results}} when is_list(results) -> length(results)
        _ -> nil
      end
    end
  end

  defp criteria_to_srql_query(criteria) when criteria == %{}, do: ""

  defp criteria_to_srql_query(criteria) when is_map(criteria) do
    clauses =
      criteria
      |> Enum.map(fn {field, spec} -> criteria_clause(field, spec) end)

    if Enum.any?(clauses, &is_nil/1) do
      ""
    else
      clauses
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")
    end
  end

  defp criteria_clause(field, spec) when is_map(spec) do
    case Map.to_list(spec) do
      [{operator, value}] -> clause_for_operator(field, operator, value)
      _ -> ""
    end
  end

  defp criteria_clause(_field, _spec), do: ""

  defp clause_for_operator("tags", operator, tags) when operator in ["has_any", "has_all"] do
    tags_to_srql(tags, operator)
  end

  defp clause_for_operator("discovery_sources", "contains", value) do
    "discovery_sources:#{escape_srql_value(value)}"
  end

  defp clause_for_operator("discovery_sources", "not_contains", value) do
    "!discovery_sources:#{escape_srql_value(value)}"
  end

  defp clause_for_operator(_field, operator, _value)
       when operator in ["in_cidr", "not_in_cidr", "in_range", "is_null", "is_not_null"] do
    nil
  end

  defp clause_for_operator(field, "eq", value), do: "#{field}:#{escape_srql_value(value)}"
  defp clause_for_operator(field, "neq", value), do: "!#{field}:#{escape_srql_value(value)}"

  defp clause_for_operator(field, "contains", value),
    do: "#{field}:#{escape_srql_value("%#{value}%")}"

  defp clause_for_operator(field, "not_contains", value),
    do: "!#{field}:#{escape_srql_value("%#{value}%")}"

  defp clause_for_operator(field, "starts_with", value),
    do: "#{field}:#{escape_srql_value("#{value}%")}"

  defp clause_for_operator(field, "ends_with", value),
    do: "#{field}:#{escape_srql_value("%#{value}")}"

  defp clause_for_operator(field, "gt", value), do: "#{field}:>#{escape_srql_value(value)}"
  defp clause_for_operator(field, "gte", value), do: "#{field}:>=#{escape_srql_value(value)}"
  defp clause_for_operator(field, "lt", value), do: "#{field}:<#{escape_srql_value(value)}"
  defp clause_for_operator(field, "lte", value), do: "#{field}:<=#{escape_srql_value(value)}"
  defp clause_for_operator(field, "in", value), do: build_list_clause(field, value, false)
  defp clause_for_operator(field, "not_in", value), do: build_list_clause(field, value, true)
  defp clause_for_operator(_field, _operator, _value), do: ""

  defp tags_to_srql(tags, operator) when is_list(tags) do
    clauses =
      tags
      |> Enum.map(&tag_to_srql/1)
      |> Enum.reject(&(&1 == ""))

    case clauses do
      [] ->
        ""

      _ ->
        separator = if operator == "has_any", do: " OR ", else: " "
        "(" <> Enum.join(clauses, separator) <> ")"
    end
  end

  defp tags_to_srql(_tags, _operator), do: ""

  defp tag_to_srql(tag) do
    value = to_string(tag) |> String.trim()

    case String.split(value, "=", parts: 2) do
      [key, val] when key != "" and val != "" ->
        "tags.#{key}:#{escape_srql_value(val)}"

      [key] when key != "" ->
        "tags:#{escape_srql_value(key)}"

      _ ->
        ""
    end
  end

  defp build_list_clause(field, values, negated) when is_list(values) do
    escaped = Enum.map_join(values, ",", &escape_srql_value/1)

    prefix = if negated, do: "!", else: ""
    "#{prefix}#{field}:(#{escaped})"
  end

  defp build_list_clause(field, value, negated) do
    build_list_clause(field, parse_list(to_string(value)), negated)
  end

  defp escape_srql_value(value) when is_binary(value) do
    if String.contains?(value, " ") do
      "\"#{value}\""
    else
      value
    end
  end

  defp escape_srql_value(value), do: to_string(value)

  defp normalize_static_targets(params) when is_map(params) do
    case Map.get(params, "static_targets") do
      nil ->
        params

      targets when is_list(targets) ->
        Map.put(params, "static_targets", Enum.map(targets, &String.trim/1))

      targets when is_binary(targets) ->
        parsed =
          targets
          |> String.split(~r/[\n,]+/, trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        Map.put(params, "static_targets", parsed)

      _ ->
        params
    end
  end
end
