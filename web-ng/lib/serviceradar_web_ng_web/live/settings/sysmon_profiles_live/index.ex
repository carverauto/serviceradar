defmodule ServiceRadarWebNGWeb.Settings.SysmonProfilesLive.Index do
  @moduledoc """
  LiveView for managing sysmon profiles configuration.

  Provides UI for:
  - Sysmon Profiles: Admin-managed monitoring configuration profiles
  - Tag Assignments: Profile assignments based on device tags
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias AshPhoenix.Form
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadar.AgentConfig.Compilers.SysmonCompiler
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.SysmonProfiles.{SysmonProfile, SysmonProfileAssignment}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(:page_title, "Sysmon Profiles")
      |> assign(:active_tab, :profiles)
      |> assign(:profiles, load_profiles(scope))
      |> assign(:assignments, load_assignments(scope))
      |> assign(:selected_profile, nil)
      |> assign(:show_form, nil)
      |> assign(:ash_form, nil)
      |> assign(:form, nil)
      |> assign(:json_preview, nil)
      |> assign(:show_assignment_form, false)
      |> assign(:assignment_form, init_assignment_form())

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Sysmon Profiles")
    |> assign(:show_form, nil)
    |> assign(:ash_form, nil)
    |> assign(:form, nil)
    |> assign(:selected_profile, nil)
    |> assign(:json_preview, nil)
  end

  defp apply_action(socket, :new_profile, _params) do
    scope = socket.assigns.current_scope
    ash_form = Form.for_create(SysmonProfile, :create, domain: ServiceRadar.SysmonProfiles, scope: scope)

    socket
    |> assign(:page_title, "New Sysmon Profile")
    |> assign(:show_form, :new_profile)
    |> assign(:ash_form, ash_form)
    |> assign(:form, to_form(ash_form))
    |> assign(:json_preview, nil)
  end

  defp apply_action(socket, :edit_profile, %{"id" => id}) do
    case load_profile(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, "Profile not found")
        |> push_navigate(to: ~p"/settings/sysmon")

      profile ->
        scope = socket.assigns.current_scope
        ash_form = Form.for_update(profile, :update, domain: ServiceRadar.SysmonProfiles, scope: scope)
        json_preview = compile_profile_preview(profile)

        socket
        |> assign(:page_title, "Edit #{profile.name}")
        |> assign(:show_form, :edit_profile)
        |> assign(:selected_profile, profile)
        |> assign(:ash_form, ash_form)
        |> assign(:form, to_form(ash_form))
        |> assign(:json_preview, json_preview)
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    active_tab =
      case tab do
        "profiles" -> :profiles
        "assignments" -> :assignments
        _ -> socket.assigns.active_tab
      end

    {:noreply, assign(socket, :active_tab, active_tab)}
  end

  def handle_event("validate_profile", %{"form" => params}, socket) do
    ash_form = socket.assigns.ash_form |> Form.validate(params)

    {:noreply,
     socket
     |> assign(:ash_form, ash_form)
     |> assign(:form, to_form(ash_form))}
  end

  def handle_event("save_profile", %{"form" => params}, socket) do
    ash_form = socket.assigns.ash_form |> Form.validate(params)
    scope = socket.assigns.current_scope

    case Form.submit(ash_form, params: params) do
      {:ok, _profile} ->
        action = if socket.assigns.show_form == :new_profile, do: "created", else: "updated"

        {:noreply,
         socket
         |> assign(:profiles, load_profiles(scope))
         |> put_flash(:info, "Profile #{action} successfully")
         |> push_navigate(to: ~p"/settings/sysmon")}

      {:error, ash_form} ->
        {:noreply,
         socket
         |> assign(:ash_form, ash_form)
         |> assign(:form, to_form(ash_form))}
    end
  end

  def handle_event("toggle_profile", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case load_profile(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Profile not found")}

      profile ->
        new_enabled = !profile.enabled
        changeset = Ash.Changeset.for_update(profile, :update, %{enabled: new_enabled})

        case Ash.update(changeset, scope: scope) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> assign(:profiles, load_profiles(scope))
             |> put_flash(:info, "Profile #{if new_enabled, do: "enabled", else: "disabled"}")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to update profile")}
        end
    end
  end

  def handle_event("delete_profile", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case load_profile(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Profile not found")}

      %{is_default: true} ->
        {:noreply, put_flash(socket, :error, "Cannot delete the default profile")}

      profile ->
        case Ash.destroy(profile, scope: scope) do
          :ok ->
            {:noreply,
             socket
             |> assign(:profiles, load_profiles(scope))
             |> put_flash(:info, "Profile deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete profile")}
        end
    end
  end

  def handle_event("set_default", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case load_profile(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Profile not found")}

      profile ->
        case Ash.update(profile, :set_as_default, scope: scope) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> assign(:profiles, load_profiles(scope))
             |> put_flash(:info, "#{profile.name} is now the default profile")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to set as default")}
        end
    end
  end

  def handle_event("preview_json", %{"id" => id}, socket) do
    case load_profile(socket.assigns.current_scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Profile not found")}

      profile ->
        json_preview = compile_profile_preview(profile)
        {:noreply, assign(socket, :json_preview, json_preview)}
    end
  end

  def handle_event("close_preview", _, socket) do
    {:noreply, assign(socket, :json_preview, nil)}
  end

  def handle_event("delete_assignment", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case load_assignment(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Assignment not found")}

      assignment ->
        case Ash.destroy(assignment, scope: scope) do
          :ok ->
            {:noreply,
             socket
             |> assign(:assignments, load_assignments(scope))
             |> put_flash(:info, "Assignment deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete assignment")}
        end
    end
  end

  def handle_event("toggle_assignment_form", _, socket) do
    {:noreply,
     socket
     |> assign(:show_assignment_form, !socket.assigns.show_assignment_form)
     |> assign(:assignment_form, init_assignment_form())}
  end

  def handle_event("validate_assignment", %{"assignment" => params}, socket) do
    assignment_form =
      socket.assigns.assignment_form
      |> Map.merge(params)

    {:noreply, assign(socket, :assignment_form, assignment_form)}
  end

  def handle_event("save_assignment", %{"assignment" => params}, socket) do
    scope = socket.assigns.current_scope

    attrs = %{
      profile_id: params["profile_id"],
      assignment_type: :tag,
      tag_key: params["tag_key"],
      tag_value: if(params["tag_value"] == "", do: nil, else: params["tag_value"]),
      priority: String.to_integer(params["priority"] || "0")
    }

    changeset = Ash.Changeset.for_create(SysmonProfileAssignment, :create, attrs)

    case Ash.create(changeset, scope: scope) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> assign(:assignments, load_assignments(scope))
         |> assign(:show_assignment_form, false)
         |> assign(:assignment_form, init_assignment_form())
         |> put_flash(:info, "Tag assignment created")}

      {:error, error} ->
        error_msg = format_ash_error(error)

        {:noreply, put_flash(socket, :error, "Failed to create assignment: #{error_msg}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.settings_shell current_path="/settings/sysmon">
      <.settings_nav current_path="/settings/sysmon" />

      <div class="space-y-4">
        <!-- Local Navigation Tabs -->
        <.local_tabs active_tab={@active_tab} />

        <!-- Content based on form state -->
        <%= if @show_form in [:new_profile, :edit_profile] do %>
          <.profile_form
            form={@form}
            show_form={@show_form}
            selected_profile={@selected_profile}
            json_preview={@json_preview}
          />
        <% else %>
          <!-- Tab Content -->
          <%= case @active_tab do %>
            <% :profiles -> %>
              <.profiles_panel profiles={@profiles} json_preview={@json_preview} />
            <% :assignments -> %>
              <.assignments_panel
                assignments={@assignments}
                profiles={@profiles}
                show_form={@show_assignment_form}
                assignment_form={@assignment_form}
              />
          <% end %>
        <% end %>
      </div>

      <!-- JSON Preview Modal -->
      <.json_preview_modal :if={@json_preview && @show_form == nil} json_preview={@json_preview} />
    </.settings_shell>
    """
  end

  # Local Navigation Tabs
  attr :active_tab, :atom, required: true

  defp local_tabs(assigns) do
    ~H"""
    <div class="flex items-center border-b border-base-200 -mb-px">
      <button
        phx-click="switch_tab"
        phx-value-tab="profiles"
        class={"px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors " <>
               if(@active_tab == :profiles, do: "border-primary text-primary", else: "border-transparent text-base-content/60 hover:text-base-content")}
      >
        Profiles
      </button>
      <button
        phx-click="switch_tab"
        phx-value-tab="assignments"
        class={"px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors " <>
               if(@active_tab == :assignments, do: "border-primary text-primary", else: "border-transparent text-base-content/60 hover:text-base-content")}
      >
        Tag Assignments
      </button>
    </div>
    """
  end

  # Profiles Panel
  attr :profiles, :list, required: true
  attr :json_preview, :any, default: nil

  defp profiles_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center justify-between w-full">
          <div>
            <div class="text-sm font-semibold">Sysmon Profiles</div>
            <p class="text-xs text-base-content/60">
              {length(@profiles)} profile(s) configured
            </p>
          </div>
          <.link navigate={~p"/settings/sysmon/new"}>
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
              <th>Status</th>
              <th>Name</th>
              <th>Interval</th>
              <th>Collectors</th>
              <th>Assignments</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@profiles == []}>
              <td colspan="6" class="text-center text-base-content/60 py-8">
                No sysmon profiles configured. Create one to start monitoring systems.
              </td>
            </tr>
            <%= for profile <- @profiles do %>
              <tr class="hover:bg-base-200/40">
                <td>
                  <button
                    phx-click="toggle_profile"
                    phx-value-id={profile.id}
                    class="flex items-center gap-1.5 cursor-pointer"
                  >
                    <span class={"size-2 rounded-full #{if profile.enabled, do: "bg-success", else: "bg-base-content/30"}"}>
                    </span>
                    <span class="text-xs">{if profile.enabled, do: "Enabled", else: "Disabled"}</span>
                  </button>
                </td>
                <td>
                  <div class="flex items-center gap-2">
                    <.link
                      navigate={~p"/settings/sysmon/#{profile.id}/edit"}
                      class="font-medium hover:text-primary"
                    >
                      {profile.name}
                    </.link>
                    <.ui_badge :if={profile.is_default} variant="info" size="xs">Default</.ui_badge>
                  </div>
                  <p :if={profile.description} class="text-xs text-base-content/60 truncate max-w-xs">
                    {profile.description}
                  </p>
                </td>
                <td class="font-mono text-xs">
                  {profile.sample_interval}
                </td>
                <td>
                  <div class="flex flex-wrap gap-1">
                    <.ui_badge :if={profile.collect_cpu} variant="ghost" size="xs">CPU</.ui_badge>
                    <.ui_badge :if={profile.collect_memory} variant="ghost" size="xs">Memory</.ui_badge>
                    <.ui_badge :if={profile.collect_disk} variant="ghost" size="xs">Disk</.ui_badge>
                    <.ui_badge :if={profile.collect_network} variant="ghost" size="xs">Network</.ui_badge>
                    <.ui_badge :if={profile.collect_processes} variant="ghost" size="xs">Processes</.ui_badge>
                  </div>
                </td>
                <td class="text-xs">
                  <span class="text-base-content/60">
                    {format_assignment_count(profile)}
                  </span>
                </td>
                <td>
                  <div class="flex items-center gap-1">
                    <.ui_button
                      variant="ghost"
                      size="xs"
                      phx-click="preview_json"
                      phx-value-id={profile.id}
                      title="Preview JSON config"
                    >
                      <.icon name="hero-code-bracket" class="size-3" />
                    </.ui_button>
                    <.link navigate={~p"/settings/sysmon/#{profile.id}/edit"}>
                      <.ui_button variant="ghost" size="xs" title="Edit profile">
                        <.icon name="hero-pencil" class="size-3" />
                      </.ui_button>
                    </.link>
                    <.ui_button
                      :if={!profile.is_default}
                      variant="ghost"
                      size="xs"
                      phx-click="set_default"
                      phx-value-id={profile.id}
                      title="Set as default"
                    >
                      <.icon name="hero-star" class="size-3" />
                    </.ui_button>
                    <.ui_button
                      :if={!profile.is_default}
                      variant="ghost"
                      size="xs"
                      phx-click="delete_profile"
                      phx-value-id={profile.id}
                      data-confirm="Are you sure you want to delete this profile?"
                      title="Delete profile"
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

  # Assignments Panel
  attr :assignments, :list, required: true
  attr :profiles, :list, required: true
  attr :show_form, :boolean, default: false
  attr :assignment_form, :map, default: %{}

  defp assignments_panel(assigns) do
    profiles_map = Map.new(assigns.profiles, &{&1.id, &1})
    tag_assignments = Enum.filter(assigns.assignments, &(&1.assignment_type == :tag))
    enabled_profiles = Enum.filter(assigns.profiles, & &1.enabled)
    assigns = assign(assigns, :profiles_map, profiles_map)
    assigns = assign(assigns, :tag_assignments, tag_assignments)
    assigns = assign(assigns, :enabled_profiles, enabled_profiles)

    ~H"""
    <div class="space-y-4">
      <.ui_panel>
        <:header>
          <div class="flex items-center justify-between w-full">
            <div>
              <div class="text-sm font-semibold">Tag Assignments</div>
              <p class="text-xs text-base-content/60">
                Assign profiles to devices based on tags. Higher priority assignments take precedence.
              </p>
            </div>
            <.ui_button variant="primary" size="sm" phx-click="toggle_assignment_form">
              <.icon name={if @show_form, do: "hero-x-mark", else: "hero-plus"} class="size-4" />
              {if @show_form, do: "Cancel", else: "New Assignment"}
            </.ui_button>
          </div>
        </:header>

        <!-- Assignment Form -->
        <div :if={@show_form} class="border-b border-base-200 pb-4 mb-4">
          <form phx-submit="save_assignment" phx-change="validate_assignment" class="space-y-4">
            <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
              <div>
                <label class="label"><span class="label-text text-xs">Tag Key</span></label>
                <input
                  type="text"
                  name="assignment[tag_key]"
                  value={@assignment_form["tag_key"]}
                  class="input input-bordered input-sm w-full"
                  placeholder="e.g., environment"
                  required
                />
              </div>
              <div>
                <label class="label"><span class="label-text text-xs">Tag Value</span></label>
                <input
                  type="text"
                  name="assignment[tag_value]"
                  value={@assignment_form["tag_value"]}
                  class="input input-bordered input-sm w-full"
                  placeholder="e.g., production (optional)"
                />
              </div>
              <div>
                <label class="label"><span class="label-text text-xs">Profile</span></label>
                <select
                  name="assignment[profile_id]"
                  class="select select-bordered select-sm w-full"
                  required
                >
                  <option value="">Select a profile...</option>
                  <%= for profile <- @enabled_profiles do %>
                    <option
                      value={profile.id}
                      selected={@assignment_form["profile_id"] == profile.id}
                    >
                      {profile.name}
                    </option>
                  <% end %>
                </select>
              </div>
              <div>
                <label class="label"><span class="label-text text-xs">Priority</span></label>
                <input
                  type="number"
                  name="assignment[priority]"
                  value={@assignment_form["priority"]}
                  class="input input-bordered input-sm w-full"
                  min="0"
                  max="100"
                />
              </div>
            </div>
            <div class="flex justify-end">
              <.ui_button type="submit" variant="primary" size="sm">
                Create Assignment
              </.ui_button>
            </div>
          </form>
        </div>

        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr class="text-xs uppercase tracking-wide text-base-content/60">
                <th>Tag</th>
                <th>Profile</th>
                <th>Devices</th>
                <th>Priority</th>
                <th>Created</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@tag_assignments == []}>
                <td colspan="6" class="text-center text-base-content/60 py-8">
                  <.icon name="hero-tag" class="size-8 mx-auto mb-2 opacity-50" />
                  <p>No tag assignments configured.</p>
                  <p class="text-xs">
                    Devices without specific assignments will use the default profile.
                  </p>
                </td>
              </tr>
              <%= for assignment <- @tag_assignments do %>
                <tr class="hover:bg-base-200/40">
                  <td>
                    <div class="font-medium">
                      <span class="text-base-content/60">{assignment.tag_key}:</span>
                      <span>{assignment.tag_value || "*"}</span>
                    </div>
                  </td>
                  <td>
                    <% profile = Map.get(@profiles_map, assignment.profile_id) %>
                    <%= if profile do %>
                      <.link
                        navigate={~p"/settings/sysmon/#{profile.id}/edit"}
                        class="link link-primary text-sm"
                      >
                        {profile.name}
                      </.link>
                    <% else %>
                      <span class="text-base-content/60 text-sm">Unknown</span>
                    <% end %>
                  </td>
                  <td>
                    <span class="text-xs font-mono">
                      {Map.get(assignment, :device_count, 0)}
                    </span>
                  </td>
                  <td class="text-xs font-mono">
                    {assignment.priority}
                  </td>
                  <td class="text-xs text-base-content/60">
                    {format_datetime(assignment.inserted_at)}
                  </td>
                  <td>
                    <.ui_button
                      variant="ghost"
                      size="xs"
                      phx-click="delete_assignment"
                      phx-value-id={assignment.id}
                      data-confirm="Are you sure you want to remove this assignment?"
                    >
                      <.icon name="hero-trash" class="size-3" />
                    </.ui_button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </.ui_panel>
    </div>
    """
  end

  # Profile Form
  attr :form, :any, required: true
  attr :show_form, :atom, required: true
  attr :selected_profile, :any, default: nil
  attr :json_preview, :any, default: nil

  defp profile_form(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="text-sm font-semibold">
          {if @show_form == :new_profile, do: "New Sysmon Profile", else: "Edit #{@selected_profile.name}"}
        </div>
      </:header>

      <.form for={@form} phx-submit="save_profile" phx-change="validate_profile" class="space-y-6">
        <!-- Basic Info Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Basic Information
          </h3>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="label"><span class="label-text">Profile Name</span></label>
              <.input
                type="text"
                field={@form[:name]}
                class="input input-bordered w-full"
                placeholder="e.g., Production Servers"
                required
              />
            </div>
            <div>
              <label class="label"><span class="label-text">Sample Interval</span></label>
              <.input
                type="text"
                field={@form[:sample_interval]}
                class="input input-bordered w-full"
                placeholder="e.g., 10s, 1m, 30s"
              />
              <label class="label">
                <span class="label-text-alt text-base-content/50">
                  How often to collect metrics (e.g., 10s, 1m, 500ms)
                </span>
              </label>
            </div>
          </div>

          <div>
            <label class="label"><span class="label-text">Description</span></label>
            <.input
              type="textarea"
              field={@form[:description]}
              class="textarea textarea-bordered w-full"
              placeholder="Optional description of this profile's purpose"
              rows="2"
            />
          </div>
        </div>

        <!-- Collectors Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Metric Collectors
          </h3>

          <div class="grid grid-cols-2 md:grid-cols-5 gap-4">
            <label class="flex items-center gap-2 cursor-pointer">
              <.input type="checkbox" field={@form[:collect_cpu]} class="checkbox checkbox-primary checkbox-sm" />
              <span class="label-text">CPU</span>
            </label>
            <label class="flex items-center gap-2 cursor-pointer">
              <.input type="checkbox" field={@form[:collect_memory]} class="checkbox checkbox-primary checkbox-sm" />
              <span class="label-text">Memory</span>
            </label>
            <label class="flex items-center gap-2 cursor-pointer">
              <.input type="checkbox" field={@form[:collect_disk]} class="checkbox checkbox-primary checkbox-sm" />
              <span class="label-text">Disk</span>
            </label>
            <label class="flex items-center gap-2 cursor-pointer">
              <.input type="checkbox" field={@form[:collect_network]} class="checkbox checkbox-primary checkbox-sm" />
              <span class="label-text">Network</span>
            </label>
            <label class="flex items-center gap-2 cursor-pointer">
              <.input type="checkbox" field={@form[:collect_processes]} class="checkbox checkbox-primary checkbox-sm" />
              <span class="label-text">Processes</span>
            </label>
          </div>
          <p class="text-xs text-base-content/50">
            Note: Process collection can be resource-intensive on systems with many processes.
          </p>
        </div>

        <!-- Disk Paths Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Disk Paths
          </h3>

          <div>
            <label class="label"><span class="label-text">Mount Points to Monitor</span></label>
            <.input
              type="text"
              field={@form[:disk_paths]}
              class="input input-bordered w-full"
              placeholder="/, /data, /var"
            />
            <label class="label">
              <span class="label-text-alt text-base-content/50">
                Comma-separated list of disk mount points
              </span>
            </label>
          </div>
        </div>

        <!-- Actions -->
        <div class="flex justify-end gap-2 pt-4 border-t border-base-200">
          <.link navigate={~p"/settings/sysmon"}>
            <.ui_button variant="ghost">Cancel</.ui_button>
          </.link>
          <.ui_button type="submit" variant="primary">
            {if @show_form == :new_profile, do: "Create Profile", else: "Save Changes"}
          </.ui_button>
        </div>
      </.form>
    </.ui_panel>

    <!-- JSON Preview (for edit mode) -->
    <.ui_panel :if={@json_preview && @show_form == :edit_profile}>
      <:header>
        <div class="text-sm font-semibold">Compiled Config Preview</div>
      </:header>
      <pre class="bg-base-200/50 p-4 rounded-lg text-xs font-mono overflow-x-auto max-h-64">{@json_preview}</pre>
    </.ui_panel>
    """
  end

  # JSON Preview Modal
  attr :json_preview, :string, required: true

  defp json_preview_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <h3 class="font-bold text-lg mb-4">Compiled Config Preview</h3>
        <pre class="bg-base-200/50 p-4 rounded-lg text-xs font-mono overflow-x-auto max-h-96">{@json_preview}</pre>
        <div class="modal-action">
          <button phx-click="close_preview" class="btn">Close</button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_preview"></div>
    </div>
    """
  end

  # Helper Functions

  defp load_profiles(scope) do
    case Ash.read(SysmonProfile, scope: scope) do
      {:ok, profiles} ->
        Enum.sort_by(profiles, & &1.inserted_at, :desc)

      {:error, _} ->
        []
    end
  end

  defp load_profile(scope, id) do
    case Ash.get(SysmonProfile, id, scope: scope) do
      {:ok, profile} -> profile
      {:error, _} -> nil
    end
  end

  defp load_assignments(scope) do
    case Ash.read(SysmonProfileAssignment, scope: scope, load: [:profile]) do
      {:ok, assignments} ->
        # Add device counts for tag assignments
        assignments_with_counts =
          assignments
          |> Enum.map(fn assignment ->
            if assignment.assignment_type == :tag do
              count = count_devices_for_tag(scope, assignment.tag_key, assignment.tag_value)
              Map.put(assignment, :device_count, count)
            else
              assignment
            end
          end)

        Enum.sort_by(assignments_with_counts, & &1.priority, :desc)

      {:error, _} ->
        []
    end
  end

  defp count_devices_for_tag(scope, tag_key, tag_value) do
    import Ash.Expr

    query =
      Device
      |> Ash.Query.for_read(:read, %{})
      |> then(fn q ->
        if is_nil(tag_value) or tag_value == "" do
          # Wildcard: count devices that have this tag key (any value)
          Ash.Query.filter(q, fragment("tags ? ?", ^tag_key))
        else
          # Specific value: count devices where tags[key] == value
          Ash.Query.filter(q, fragment("tags ->> ? = ?", ^tag_key, ^tag_value))
        end
      end)

    case Ash.count(query, scope: scope) do
      {:ok, count} -> count
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp load_assignment(scope, id) do
    case Ash.get(SysmonProfileAssignment, id, scope: scope) do
      {:ok, assignment} -> assignment
      {:error, _} -> nil
    end
  end

  defp compile_profile_preview(profile) do
    config = SysmonCompiler.compile_profile(profile, "preview", %{}, "profile")
    Jason.encode!(config, pretty: true)
  rescue
    _ -> "{\"error\": \"Failed to compile config\"}"
  end

  defp format_assignment_count(profile) do
    count = Map.get(profile, :assignment_count) || 0

    case count do
      0 -> "No assignments"
      1 -> "1 assignment"
      n -> "#{n} assignments"
    end
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end

  defp init_assignment_form do
    %{
      "profile_id" => "",
      "tag_key" => "",
      "tag_value" => "",
      "priority" => "0"
    }
  end

  defp format_ash_error(%Ash.Error.Invalid{errors: errors}) do
    errors
    |> Enum.map(fn
      %{field: field, message: msg} -> "#{field}: #{msg}"
      %{message: msg} -> msg
      other -> inspect(other)
    end)
    |> Enum.join(", ")
  end

  defp format_ash_error(error) do
    inspect(error)
  end
end
