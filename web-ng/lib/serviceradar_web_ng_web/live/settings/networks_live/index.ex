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

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadar.SweepJobs.{SweepGroup, SweepGroupExecution, SweepProfile}

  @refresh_interval :timer.seconds(15)

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "sweep:executions")
      # Refresh active scans periodically
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
      |> assign(:selected_group, nil)
      |> assign(:selected_profile, nil)
      |> assign(:show_form, nil)
      |> assign(:form, nil)

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
    |> assign(:selected_group, nil)
    |> assign(:selected_profile, nil)
  end

  defp apply_action(socket, :new_group, _params) do
    changeset = SweepGroup |> Ash.Changeset.for_create(:create, %{})

    socket
    |> assign(:page_title, "New Sweep Group")
    |> assign(:show_form, :new_group)
    |> assign(:form, to_form(changeset))
  end

  defp apply_action(socket, :edit_group, %{"id" => id}) do
    case load_sweep_group(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, "Sweep group not found")
        |> push_navigate(to: ~p"/settings/networks")

      group ->
        changeset = group |> Ash.Changeset.for_update(:update, %{})

        socket
        |> assign(:page_title, "Edit Sweep Group")
        |> assign(:show_form, :edit_group)
        |> assign(:selected_group, group)
        |> assign(:form, to_form(changeset))
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
    changeset = SweepProfile |> Ash.Changeset.for_create(:create, %{})

    socket
    |> assign(:page_title, "New Scanner Profile")
    |> assign(:show_form, :new_profile)
    |> assign(:form, to_form(changeset))
  end

  defp apply_action(socket, :edit_profile, %{"id" => id}) do
    case load_sweep_profile(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, "Scanner profile not found")
        |> push_navigate(to: ~p"/settings/networks")

      profile ->
        changeset = profile |> Ash.Changeset.for_update(:update, %{})

        socket
        |> assign(:page_title, "Edit Scanner Profile")
        |> assign(:show_form, :edit_profile)
        |> assign(:selected_profile, profile)
        |> assign(:form, to_form(changeset))
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

        case Ash.update(group, action, actor: build_actor(scope), tenant: get_tenant(scope)) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> assign(:sweep_groups, load_sweep_groups(scope))
             |> put_flash(:info, "Sweep group #{if action == :enable, do: "enabled", else: "disabled"}")}

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
        case Ash.destroy(group, actor: build_actor(scope), tenant: get_tenant(scope)) do
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
        case Ash.destroy(profile, actor: build_actor(scope), tenant: get_tenant(scope)) do
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
    actor = build_actor(scope)
    tenant = get_tenant(scope)

    result =
      case socket.assigns.show_form do
        :new_group ->
          SweepGroup
          |> Ash.Changeset.for_create(:create, params, actor: actor, tenant: tenant)
          |> Ash.create()

        :edit_group ->
          socket.assigns.selected_group
          |> Ash.Changeset.for_update(:update, params, actor: actor, tenant: tenant)
          |> Ash.update()
      end

    case result do
      {:ok, _group} ->
        {:noreply,
         socket
         |> assign(:sweep_groups, load_sweep_groups(scope))
         |> put_flash(:info, "Sweep group saved")
         |> push_navigate(to: ~p"/settings/networks")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("save_profile", %{"form" => params}, socket) do
    scope = socket.assigns.current_scope
    actor = build_actor(scope)
    tenant = get_tenant(scope)

    result =
      case socket.assigns.show_form do
        :new_profile ->
          SweepProfile
          |> Ash.Changeset.for_create(:create, params, actor: actor, tenant: tenant)
          |> Ash.create()

        :edit_profile ->
          socket.assigns.selected_profile
          |> Ash.Changeset.for_update(:update, params, actor: actor, tenant: tenant)
          |> Ash.update()
      end

    case result do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> assign(:sweep_profiles, load_sweep_profiles(scope))
         |> put_flash(:info, "Scanner profile saved")
         |> push_navigate(to: ~p"/settings/networks")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("validate_group", %{"form" => params}, socket) do
    scope = socket.assigns.current_scope
    actor = build_actor(scope)
    tenant = get_tenant(scope)

    changeset =
      case socket.assigns.show_form do
        :new_group ->
          SweepGroup
          |> Ash.Changeset.for_create(:create, params, actor: actor, tenant: tenant)

        :edit_group ->
          socket.assigns.selected_group
          |> Ash.Changeset.for_update(:update, params, actor: actor, tenant: tenant)
      end

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("validate_profile", %{"form" => params}, socket) do
    scope = socket.assigns.current_scope
    actor = build_actor(scope)
    tenant = get_tenant(scope)

    changeset =
      case socket.assigns.show_form do
        :new_profile ->
          SweepProfile
          |> Ash.Changeset.for_create(:create, params, actor: actor, tenant: tenant)

        :edit_profile ->
          socket.assigns.selected_profile
          |> Ash.Changeset.for_update(:update, params, actor: actor, tenant: tenant)
      end

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_info(:refresh_active_scans, socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(:running_executions, load_running_executions(scope))
     |> assign(:recent_executions, load_recent_executions(scope))}
  end

  def handle_info({:sweep_execution_update, _execution}, socket) do
    # Real-time update from PubSub
    scope = socket.assigns.current_scope

    {:noreply,
     socket
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
          <.group_form form={@form} show_form={@show_form} profiles={@sweep_profiles} />
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
            <.running_scan_card execution={execution} group={Map.get(@groups_map, execution.sweep_group_id)} />
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
              </tr>
            </thead>
            <tbody>
              <%= for execution <- @recent do %>
                <.recent_execution_row execution={execution} group={Map.get(@groups_map, execution.sweep_group_id)} />
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
    available_hosts = Enum.reduce(completed_recent, 0, fn e, acc -> acc + (e.hosts_available || 0) end)

    avg_success_rate =
      if length(completed_recent) > 0 do
        completed_recent
        |> Enum.map(fn e ->
          if e.hosts_total && e.hosts_total > 0 do
            (e.hosts_available || 0) / e.hosts_total * 100
          else
            0
          end
        end)
        |> Enum.sum()
        |> Kernel./(length(completed_recent))
        |> Float.round(1)
      else
        0.0
      end

    failed_count = Enum.count(assigns.recent, &(&1.status == :failed))

    assigns =
      assigns
      |> assign(:total_hosts, total_hosts)
      |> assign(:available_hosts, available_hosts)
      |> assign(:avg_success_rate, avg_success_rate)
      |> assign(:failed_count, failed_count)
      |> assign(:completed_count, length(completed_recent))

    ~H"""
    <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
      <div class="bg-base-200/50 rounded-lg p-4">
        <div class="text-xs text-base-content/60 uppercase tracking-wide">Running</div>
        <div class="text-2xl font-bold mt-1 flex items-center gap-2">
          {length(@running)}
          <span :if={length(@running) > 0} class="size-2 rounded-full bg-success animate-pulse"></span>
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
    """
  end

  # Running Scan Card Component
  attr :execution, :map, required: true
  attr :group, :map, default: nil

  defp running_scan_card(assigns) do
    # Calculate elapsed time
    elapsed_ms =
      if assigns.execution.started_at do
        DateTime.diff(DateTime.utc_now(), assigns.execution.started_at, :millisecond)
      else
        0
      end

    assigns = assign(assigns, :elapsed_ms, elapsed_ms)

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
          <div :if={@execution.hosts_total && @execution.hosts_total > 0} class="text-xs text-base-content/60">
            {@execution.hosts_available || 0} / {@execution.hosts_total} hosts
          </div>
        </div>
      </div>

      <!-- Progress bar -->
      <div :if={@execution.hosts_total && @execution.hosts_total > 0} class="mt-3">
        <div class="h-1.5 bg-base-300 rounded-full overflow-hidden">
          <div
            class="h-full bg-success transition-all duration-300"
            style={"width: #{progress_percent(@execution)}%"}
          >
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Recent Execution Row Component
  attr :execution, :map, required: true
  attr :group, :map, default: nil

  defp recent_execution_row(assigns) do
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
    </tr>
    """
  end

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

  defp progress_percent(%{hosts_total: total, hosts_available: available, hosts_failed: failed})
       when is_integer(total) and total > 0 do
    scanned = (available || 0) + (failed || 0)
    Float.round(scanned / total * 100, 1)
  end

  defp progress_percent(_), do: 0

  defp format_relative_time(nil), do: "—"

  defp format_relative_time(%DateTime{} = dt) do
    diff_seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff_seconds < 60 -> "#{diff_seconds}s ago"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86400 -> "#{div(diff_seconds, 3600)}h ago"
      true -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
    end
  end

  defp format_relative_time(_), do: "—"

  defp format_duration(nil), do: "—"
  defp format_duration(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when is_integer(ms) and ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"

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

  defp group_form(assigns) do
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

      <.form for={@form} phx-submit="save_group" phx-change="validate_group" class="space-y-4">
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

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div>
            <label class="label">
              <span class="label-text">Schedule Interval</span>
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
              <span class="label-text">Scanner Profile (optional)</span>
            </label>
            <.input
              type="select"
              field={@form[:profile_id]}
              class="select select-bordered w-full"
              options={[{"None", ""} | Enum.map(@profiles, &{&1.name, &1.id})]}
            />
          </div>
        </div>

        <div>
          <label class="label">
            <span class="label-text">Static Targets (CIDRs or IPs, one per line)</span>
          </label>
          <.input
            type="textarea"
            field={@form[:static_targets]}
            class="textarea textarea-bordered w-full font-mono text-sm"
            rows="4"
            placeholder="10.0.1.0/24&#10;192.168.1.0/24&#10;172.16.0.1"
          />
        </div>

        <div class="flex items-center gap-2">
          <.input type="checkbox" field={@form[:enabled]} class="checkbox checkbox-primary" />
          <label class="label-text">Enabled</label>
        </div>

        <div class="flex justify-end gap-2 pt-4">
          <.link navigate={~p"/settings/networks"}>
            <.ui_button variant="ghost">Cancel</.ui_button>
          </.link>
          <.ui_button type="submit" variant="primary">Save Sweep Group</.ui_button>
        </div>
      </.form>
    </.ui_panel>
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
          <div :if={@group.target_criteria != %{}} class="space-y-1">
            <div class="text-xs text-base-content/60 uppercase">Target Criteria</div>
            <pre class="bg-base-200 p-2 rounded text-xs font-mono overflow-x-auto">{Jason.encode!(@group.target_criteria, pretty: true)}</pre>
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
    actor = build_actor(scope)
    tenant = get_tenant(scope)

    case Ash.read(SweepGroup, actor: actor, tenant: tenant, authorize?: false) do
      {:ok, groups} -> groups
      {:error, _} -> []
    end
  end

  defp load_sweep_group(scope, id) do
    actor = build_actor(scope)
    tenant = get_tenant(scope)

    case Ash.get(SweepGroup, id, actor: actor, tenant: tenant, authorize?: false) do
      {:ok, group} -> group
      {:error, _} -> nil
    end
  end

  defp load_sweep_profiles(scope) do
    actor = build_actor(scope)
    tenant = get_tenant(scope)

    case Ash.read(SweepProfile, actor: actor, tenant: tenant, authorize?: false) do
      {:ok, profiles} -> profiles
      {:error, _} -> []
    end
  end

  defp load_sweep_profile(scope, id) do
    actor = build_actor(scope)
    tenant = get_tenant(scope)

    case Ash.get(SweepProfile, id, actor: actor, tenant: tenant, authorize?: false) do
      {:ok, profile} -> profile
      {:error, _} -> nil
    end
  end

  defp load_running_executions(scope) do
    actor = build_actor(scope)
    tenant = get_tenant(scope)

    case Ash.read(SweepGroupExecution, action: :running, actor: actor, tenant: tenant, authorize?: false) do
      {:ok, executions} -> executions
      {:error, _} -> []
    end
  end

  defp load_recent_executions(scope) do
    actor = build_actor(scope)
    tenant = get_tenant(scope)

    case Ash.read(SweepGroupExecution,
           action: :recent,
           actor: actor,
           tenant: tenant,
           authorize?: false
         ) do
      {:ok, executions} ->
        # Filter out running ones (they appear in the running section)
        Enum.reject(executions, &(&1.status == :running))

      {:error, _} ->
        []
    end
  end

  defp build_actor(scope) do
    case scope do
      %{user: user} when not is_nil(user) ->
        %{
          id: user.id,
          email: user.email,
          role: user.role,
          tenant_id: Scope.tenant_id(scope)
        }

      _ ->
        %{id: "system", email: "system@serviceradar", role: :admin}
    end
  end

  defp get_tenant(scope) do
    case Scope.tenant_id(scope) do
      nil -> nil
      tenant_id -> ServiceRadarWebNGWeb.TenantResolver.schema_for_tenant_id(tenant_id)
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
end
