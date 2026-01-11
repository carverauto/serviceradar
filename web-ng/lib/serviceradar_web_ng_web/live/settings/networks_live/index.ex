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
  alias ServiceRadar.SweepJobs.{SweepGroup, SweepProfile}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(:page_title, "Network Sweeps")
      |> assign(:active_tab, :groups)
      |> assign(:sweep_groups, load_sweep_groups(scope))
      |> assign(:sweep_profiles, load_sweep_profiles(scope))
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
              <.tab_navigation active_tab={@active_tab} />

              <%= if @active_tab == :groups do %>
                <.sweep_groups_panel groups={@sweep_groups} />
              <% else %>
                <.profiles_panel profiles={@sweep_profiles} />
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
