defmodule ServiceRadarWebNGWeb.Settings.SysmonProfilesLive.Index do
  @moduledoc """
  LiveView for managing sysmon profiles configuration.

  Provides UI for:
  - Sysmon Profiles: Admin-managed monitoring configuration profiles with SRQL targeting
  """
  use ServiceRadarWebNGWeb, :live_view

  require Ash.Query

  import ServiceRadarWebNGWeb.SettingsComponents
  import ServiceRadarWebNGWeb.QueryBuilderComponents

  alias AshPhoenix.Form
  alias ServiceRadar.AgentConfig.Compilers.SysmonCompiler
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.SysmonProfiles.SysmonProfile
  alias ServiceRadarWebNGWeb.SRQL.Catalog

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(:page_title, "Sysmon Profiles")
      |> assign(:profiles, load_profiles(scope))
      |> assign(:selected_profile, nil)
      |> assign(:show_form, nil)
      |> assign(:ash_form, nil)
      |> assign(:form, nil)
      |> assign(:json_preview, nil)
      |> assign(:target_device_count, nil)
      |> assign(:builder_open, false)
      |> assign(:builder, default_builder_state())
      |> assign(:builder_sync, true)

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
    |> assign(:builder_open, false)
    |> assign(:builder, default_builder_state())
  end

  defp apply_action(socket, :new_profile, _params) do
    scope = socket.assigns.current_scope

    ash_form =
      Form.for_create(SysmonProfile, :create, domain: ServiceRadar.SysmonProfiles, scope: scope)

    socket
    |> assign(:page_title, "New Sysmon Profile")
    |> assign(:show_form, :new_profile)
    |> assign(:ash_form, ash_form)
    |> assign(:form, to_form(ash_form))
    |> assign(:json_preview, nil)
    |> assign(:builder_open, false)
    |> assign(:builder, default_builder_state())
    |> assign(:builder_sync, true)
    |> assign(:target_device_count, nil)
  end

  defp apply_action(socket, :edit_profile, %{"id" => id}) do
    case load_profile(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, "Profile not found")
        |> push_navigate(to: ~p"/settings/sysmon")

      profile ->
        scope = socket.assigns.current_scope

        ash_form =
          Form.for_update(profile, :update, domain: ServiceRadar.SysmonProfiles, scope: scope)

        json_preview = compile_profile_preview(profile)
        device_count = count_target_devices(scope, profile.target_query)

        # Parse the existing target_query into builder state if possible
        {builder, builder_sync} = parse_target_query_to_builder(profile.target_query)

        socket
        |> assign(:page_title, "Edit #{profile.name}")
        |> assign(:show_form, :edit_profile)
        |> assign(:selected_profile, profile)
        |> assign(:ash_form, ash_form)
        |> assign(:form, to_form(ash_form))
        |> assign(:json_preview, json_preview)
        |> assign(:target_device_count, device_count)
        |> assign(:builder_open, false)
        |> assign(:builder, builder)
        |> assign(:builder_sync, builder_sync)
    end
  end

  @impl true
  def handle_event("validate_profile", %{"form" => params}, socket) do
    scope = socket.assigns.current_scope
    target_query = Map.get(params, "target_query")
    device_count = count_target_devices(scope, target_query)
    ash_form = socket.assigns.ash_form |> Form.validate(params)
    {parsed_builder, builder_sync} = parse_target_query_to_builder(target_query)

    socket =
      socket
      |> assign(:ash_form, ash_form)
      |> assign(:form, to_form(ash_form))
      |> assign(:target_device_count, device_count)
      |> assign(:builder_sync, builder_sync)

    socket =
      if builder_sync do
        assign(socket, :builder, parsed_builder)
      else
        socket
      end

    {:noreply, socket}
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

  # Builder event handlers

  def handle_event("builder_toggle", _params, socket) do
    builder_open = !socket.assigns.builder_open

    socket =
      if builder_open do
        # When opening, try to parse current target_query into builder
        form_data =
          socket.assigns.ash_form |> Form.params() |> Map.new(fn {k, v} -> {to_string(k), v} end)

        target_query = Map.get(form_data, "target_query", "")
        {builder, builder_sync} = parse_target_query_to_builder(target_query)

        socket
        |> assign(:builder_open, true)
        |> assign(:builder, builder)
        |> assign(:builder_sync, builder_sync)
      else
        assign(socket, :builder_open, false)
      end

    {:noreply, socket}
  end

  def handle_event("builder_change", %{"builder" => builder_params}, socket) do
    builder = update_builder(socket.assigns.builder, builder_params)

    socket =
      socket
      |> assign(:builder, builder)
      |> maybe_sync_builder_to_form()

    {:noreply, socket}
  end

  def handle_event("builder_add_filter", _params, socket) do
    builder = socket.assigns.builder
    config = Catalog.entity("devices")

    filters =
      builder
      |> Map.get("filters", [])
      |> List.wrap()

    next = %{
      "field" => config.default_filter_field,
      "op" => "contains",
      "value" => ""
    }

    updated_builder = Map.put(builder, "filters", filters ++ [next])

    socket =
      socket
      |> assign(:builder, updated_builder)
      |> maybe_sync_builder_to_form()

    {:noreply, socket}
  end

  def handle_event("builder_remove_filter", %{"idx" => idx_str}, socket) do
    builder = socket.assigns.builder

    filters =
      builder
      |> Map.get("filters", [])
      |> List.wrap()

    index =
      case Integer.parse(idx_str) do
        {i, ""} -> i
        _ -> -1
      end

    updated_filters =
      filters
      |> Enum.with_index()
      |> Enum.reject(fn {_f, i} -> i == index end)
      |> Enum.map(fn {f, _i} -> f end)

    updated_builder = Map.put(builder, "filters", updated_filters)

    socket =
      socket
      |> assign(:builder, updated_builder)
      |> maybe_sync_builder_to_form()

    {:noreply, socket}
  end

  def handle_event("builder_apply", _params, socket) do
    builder = socket.assigns.builder
    query = build_target_query(builder)

    # Update the form with the new target_query
    ash_form =
      socket.assigns.ash_form
      |> Form.validate(%{"target_query" => query})

    scope = socket.assigns.current_scope
    device_count = count_target_devices(scope, query)

    {:noreply,
     socket
     |> assign(:ash_form, ash_form)
     |> assign(:form, to_form(ash_form))
     |> assign(:builder_sync, true)
     |> assign(:target_device_count, device_count)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.settings_shell current_path="/settings/sysmon">
      <.settings_nav current_path="/settings/sysmon" />

      <div class="space-y-4">
        <!-- Content based on form state -->
        <%= if @show_form in [:new_profile, :edit_profile] do %>
          <.profile_form
            form={@form}
            show_form={@show_form}
            selected_profile={@selected_profile}
            json_preview={@json_preview}
            target_device_count={@target_device_count}
            builder_open={@builder_open}
            builder={@builder}
            builder_sync={@builder_sync}
          />
        <% else %>
          <.profiles_panel profiles={@profiles} json_preview={@json_preview} />
        <% end %>
      </div>
      
    <!-- JSON Preview Modal -->
      <.json_preview_modal :if={@json_preview && @show_form == nil} json_preview={@json_preview} />
    </.settings_shell>
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
              <th>Targeting</th>
              <th>Interval</th>
              <th>Collectors</th>
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
                <td class="text-xs max-w-xs">
                  <%= cond do %>
                    <% profile.is_default -> %>
                      <span class="text-base-content/60 italic">All unmatched devices</span>
                    <% profile.target_query && profile.target_query != "" -> %>
                      <code
                        class="font-mono text-[11px] bg-base-200/50 px-1.5 py-0.5 rounded truncate block max-w-[200px]"
                        title={profile.target_query}
                      >
                        {profile.target_query}
                      </code>
                    <% true -> %>
                      <span class="text-base-content/40">No targeting</span>
                  <% end %>
                </td>
                <td class="font-mono text-xs">
                  {profile.sample_interval}
                </td>
                <td>
                  <div class="flex flex-wrap gap-1">
                    <.ui_badge :if={profile.collect_cpu} variant="ghost" size="xs">CPU</.ui_badge>
                    <.ui_badge :if={profile.collect_memory} variant="ghost" size="xs">
                      Memory
                    </.ui_badge>
                    <.ui_badge :if={profile.collect_disk} variant="ghost" size="xs">Disk</.ui_badge>
                    <.ui_badge :if={profile.collect_network} variant="ghost" size="xs">
                      Network
                    </.ui_badge>
                    <.ui_badge :if={profile.collect_processes} variant="ghost" size="xs">
                      Processes
                    </.ui_badge>
                  </div>
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

  # Profile Form
  attr :form, :any, required: true
  attr :show_form, :atom, required: true
  attr :selected_profile, :any, default: nil
  attr :json_preview, :any, default: nil
  attr :target_device_count, :integer, default: nil
  attr :builder_open, :boolean, default: false
  attr :builder, :map, default: %{}
  attr :builder_sync, :boolean, default: true

  defp profile_form(assigns) do
    is_default = assigns.selected_profile && assigns.selected_profile.is_default
    config = Catalog.entity("devices")

    assigns =
      assigns
      |> assign(:is_default, is_default)
      |> assign(:config, config)

    ~H"""
    <.ui_panel>
      <:header>
        <div class="text-sm font-semibold">
          {if @show_form == :new_profile,
            do: "New Sysmon Profile",
            else: "Edit #{@selected_profile.name}"}
        </div>
      </:header>

      <.form
        for={@form}
        id="sysmon-profile-form"
        phx-submit="save_profile"
        phx-change="validate_profile"
        phx-debounce="300"
        class="space-y-6"
      >
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
        
    <!-- Device Targeting Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Device Targeting
          </h3>

          <%= if @is_default do %>
            <div class="bg-info/10 border border-info/30 rounded-lg p-4">
              <div class="flex items-start gap-3">
                <.icon name="hero-information-circle" class="size-5 text-info shrink-0 mt-0.5" />
                <div>
                  <p class="text-sm font-medium">Default Profile</p>
                  <p class="text-xs text-base-content/70 mt-1">
                    This is the default profile for your tenant. It will be applied to all devices
                    that don't match any other profile's targeting query.
                  </p>
                </div>
              </div>
            </div>
          <% else %>
            <div class="space-y-4">
              <!-- Query Input with Builder Toggle -->
              <div>
                <label class="label"><span class="label-text">Target Query (SRQL)</span></label>
                <div class="flex items-center gap-2">
                  <div class="flex-1">
                    <.input
                      type="text"
                      field={@form[:target_query]}
                      class="input input-bordered w-full font-mono text-sm"
                      placeholder="e.g., tags.role:database hostname:%prod%"
                    />
                  </div>
                  <.ui_icon_button
                    active={@builder_open}
                    aria-label="Toggle query builder"
                    title="Query builder"
                    phx-click="builder_toggle"
                  >
                    <.icon name="hero-adjustments-horizontal" class="size-4" />
                  </.ui_icon_button>
                </div>
                <label class="label">
                  <span class="label-text-alt text-base-content/50">
                    SRQL filters to match devices. Examples: <code class="bg-base-200 px-1 rounded">tags.environment:production</code>, <code class="bg-base-200 px-1 rounded">hostname:%prod%</code>,
                    <code class="bg-base-200 px-1 rounded">type:Server</code>
                  </span>
                </label>
              </div>
              
    <!-- Visual Query Builder -->
              <div :if={@builder_open} class="border border-base-200 rounded-lg p-4 bg-base-100/50">
                <div class="flex items-center justify-between mb-4">
                  <div class="text-sm font-semibold">Query Builder</div>
                  <div class="flex items-center gap-2">
                    <.ui_badge :if={not @builder_sync} size="sm">Not applied</.ui_badge>
                    <.ui_button
                      :if={not @builder_sync}
                      size="sm"
                      variant="ghost"
                      type="button"
                      phx-click="builder_apply"
                    >
                      Apply to query
                    </.ui_button>
                  </div>
                </div>

                <form phx-change="builder_change" autocomplete="off">
                  <div class="flex flex-col gap-4">
                    <!-- Filters Section -->
                    <div class="flex flex-col gap-3">
                      <div class="text-xs text-base-content/60 font-medium">
                        Match devices where:
                      </div>

                      <%= for {filter, idx} <- Enum.with_index(Map.get(@builder, "filters", [])) do %>
                        <div class="flex items-center gap-3">
                          <.query_builder_pill label="Filter">
                            <%= if @config.filter_fields == [] do %>
                              <.ui_inline_input
                                type="text"
                                name={"builder[filters][#{idx}][field]"}
                                value={filter["field"] || ""}
                                placeholder="field"
                                class="w-40 placeholder:text-base-content/40"
                              />
                            <% else %>
                              <.ui_inline_select name={"builder[filters][#{idx}][field]"}>
                                <%= for field <- @config.filter_fields do %>
                                  <option value={field} selected={filter["field"] == field}>
                                    {field}
                                  </option>
                                <% end %>
                              </.ui_inline_select>
                            <% end %>

                            <.ui_inline_select
                              name={"builder[filters][#{idx}][op]"}
                              class="text-xs text-base-content/70"
                            >
                              <option
                                value="contains"
                                selected={(filter["op"] || "contains") == "contains"}
                              >
                                contains
                              </option>
                              <option value="not_contains" selected={filter["op"] == "not_contains"}>
                                does not contain
                              </option>
                              <option value="equals" selected={filter["op"] == "equals"}>
                                equals
                              </option>
                              <option value="not_equals" selected={filter["op"] == "not_equals"}>
                                does not equal
                              </option>
                            </.ui_inline_select>

                            <.ui_inline_input
                              type="text"
                              name={"builder[filters][#{idx}][value]"}
                              value={filter["value"] || ""}
                              placeholder="value"
                              class="placeholder:text-base-content/40 w-48"
                            />
                          </.query_builder_pill>

                          <.ui_icon_button
                            size="xs"
                            aria-label="Remove filter"
                            title="Remove filter"
                            type="button"
                            phx-click="builder_remove_filter"
                            phx-value-idx={idx}
                          >
                            <.icon name="hero-x-mark" class="size-4" />
                          </.ui_icon_button>
                        </div>
                      <% end %>

                      <button
                        type="button"
                        class="inline-flex items-center gap-2 rounded-md border border-dashed border-primary/40 px-3 py-2 text-sm text-primary/80 hover:bg-primary/5 w-fit"
                        phx-click="builder_add_filter"
                      >
                        <.icon name="hero-plus" class="size-4" /> Add filter
                      </button>
                    </div>
                  </div>
                </form>
              </div>
              
    <!-- Device Count Preview -->
              <div :if={@target_device_count != nil} class="flex items-center gap-2">
                <.icon name="hero-device-phone-mobile" class="size-4 text-base-content/60" />
                <span class="text-sm">
                  <span class="font-semibold">{@target_device_count}</span>
                  <span class="text-base-content/60">device(s) match this query</span>
                </span>
              </div>
              
    <!-- Priority -->
              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div>
                  <label class="label"><span class="label-text">Priority</span></label>
                  <.input
                    type="number"
                    field={@form[:priority]}
                    class="input input-bordered w-full"
                    min="0"
                    max="100"
                  />
                  <label class="label">
                    <span class="label-text-alt text-base-content/50">
                      Higher priority profiles are evaluated first (0-100)
                    </span>
                  </label>
                </div>
              </div>
            </div>
          <% end %>
        </div>
        
    <!-- Collectors Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Metric Collectors
          </h3>

          <div class="grid grid-cols-2 md:grid-cols-5 gap-4">
            <label class="flex items-center gap-2 cursor-pointer">
              <.input
                type="checkbox"
                field={@form[:collect_cpu]}
                class="checkbox checkbox-primary checkbox-sm"
              />
              <span class="label-text">CPU</span>
            </label>
            <label class="flex items-center gap-2 cursor-pointer">
              <.input
                type="checkbox"
                field={@form[:collect_memory]}
                class="checkbox checkbox-primary checkbox-sm"
              />
              <span class="label-text">Memory</span>
            </label>
            <label class="flex items-center gap-2 cursor-pointer">
              <.input
                type="checkbox"
                field={@form[:collect_disk]}
                class="checkbox checkbox-primary checkbox-sm"
              />
              <span class="label-text">Disk</span>
            </label>
            <label class="flex items-center gap-2 cursor-pointer">
              <.input
                type="checkbox"
                field={@form[:collect_network]}
                class="checkbox checkbox-primary checkbox-sm"
              />
              <span class="label-text">Network</span>
            </label>
            <label class="flex items-center gap-2 cursor-pointer">
              <.input
                type="checkbox"
                field={@form[:collect_processes]}
                class="checkbox checkbox-primary checkbox-sm"
              />
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
        # Sort by priority (highest first), then by name
        profiles
        |> Enum.sort_by(fn p -> {-p.priority, p.name} end)

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

  defp compile_profile_preview(profile) do
    config = SysmonCompiler.compile_profile(profile)
    Jason.encode!(config, pretty: true)
  rescue
    _ -> "{\"error\": \"Failed to compile config\"}"
  end

  defp count_target_devices(_scope, nil), do: nil
  defp count_target_devices(_scope, ""), do: nil

  defp count_target_devices(scope, target_query) when is_binary(target_query) do
    # Parse the SRQL query and count matching devices
    case ServiceRadarSRQL.Native.parse_ast(target_query) do
      {:ok, ast_json} ->
        case Jason.decode(ast_json) do
          {:ok, ast} ->
            count_devices_from_ast(scope, ast)

          {:error, _} ->
            nil
        end

      {:error, _} ->
        nil
    end
  rescue
    _ -> nil
  end

  defp count_devices_from_ast(scope, ast) do
    filters = extract_srql_filters(ast)

    query =
      Device
      |> Ash.Query.for_read(:read, %{})
      |> apply_srql_filters(filters)

    case Ash.count(query, scope: scope) do
      {:ok, count} -> count
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp extract_srql_filters(%{"filters" => filters}) when is_list(filters) do
    Enum.map(filters, fn filter ->
      %{
        field: Map.get(filter, "field"),
        op: Map.get(filter, "op", "eq"),
        value: Map.get(filter, "value")
      }
    end)
  end

  defp extract_srql_filters(_), do: []

  defp apply_srql_filters(query, filters) do
    Enum.reduce(filters, query, fn filter, q ->
      apply_srql_filter(q, filter)
    end)
  end

  defp apply_srql_filter(query, %{field: field, op: op, value: value}) when is_binary(field) do
    if String.starts_with?(field, "tags.") do
      tag_key = String.replace_prefix(field, "tags.", "")
      # Tags only support equality matching via JSONB containment
      Ash.Query.filter(query, fragment("tags @> ?", ^%{tag_key => value}))
    else
      # Map common fields
      mapped_field =
        case field do
          "hostname" -> :hostname
          "uid" -> :uid
          "type" -> :type_id
          "os" -> :os
          "status" -> :status
          _ -> nil
        end

      if mapped_field do
        apply_field_filter(query, mapped_field, op, value)
      else
        query
      end
    end
  rescue
    _ -> query
  end

  defp apply_srql_filter(query, _), do: query

  # Apply filter based on SRQL operator (op comes from rust parser: eq, not_eq, like, not_like)
  defp apply_field_filter(query, field, "eq", value) do
    Ash.Query.filter_input(query, %{field => %{eq: value}})
  end

  defp apply_field_filter(query, field, "not_eq", value) do
    Ash.Query.filter_input(query, %{field => %{not_eq: value}})
  end

  defp apply_field_filter(query, field, "like", value) do
    # SRQL "like" values contain % wildcards (e.g., "%test%"), strip them for Ash contains
    stripped = value |> String.trim_leading("%") |> String.trim_trailing("%")
    Ash.Query.filter_input(query, %{field => %{contains: stripped}})
  end

  defp apply_field_filter(query, _field, "not_like", _value) do
    # Ash filter_input doesn't have a direct not_contains operator.
    # Skip this filter - device count will be an approximation for not_like queries.
    query
  end

  defp apply_field_filter(query, field, _op, value) do
    # Default to equality for unknown operators
    Ash.Query.filter_input(query, %{field => %{eq: value}})
  end

  # Builder Helper Functions

  defp default_builder_state do
    config = Catalog.entity("devices")

    %{
      "filters" => [
        %{
          "field" => config.default_filter_field,
          "op" => "contains",
          "value" => ""
        }
      ]
    }
  end

  defp parse_target_query_to_builder(nil), do: {default_builder_state(), true}
  defp parse_target_query_to_builder(""), do: {default_builder_state(), true}

  defp parse_target_query_to_builder(query) when is_binary(query) do
    # Try to parse the query into builder filters
    # For profile targeting, we only support simple filter expressions like:
    # hostname:%prod% tags.role:database
    query = String.trim(query)

    if query == "" do
      {default_builder_state(), true}
    else
      case parse_filters_from_query(query) do
        {:ok, filters} when filters != [] ->
          {%{"filters" => filters}, true}

        _ ->
          # Query is too complex for the builder
          {default_builder_state(), false}
      end
    end
  end

  defp parse_filters_from_query(query) do
    # Split by whitespace, but handle escaped spaces
    # Filter out known SRQL keywords that aren't filter expressions
    known_prefixes = ["in:", "limit:", "sort:", "time:"]

    tokens =
      query
      |> String.split(~r/(?<!\\)\s+/, trim: true)
      |> Enum.reject(fn token ->
        Enum.any?(known_prefixes, &String.starts_with?(token, &1))
      end)

    filters =
      tokens
      |> Enum.map(&parse_filter_token/1)
      |> Enum.reject(&is_nil/1)

    if length(filters) == length(tokens) do
      {:ok, filters}
    else
      {:error, :unsupported_query}
    end
  end

  defp parse_filter_token(token) do
    # Parse tokens like: field:value, field:%value%, !field:value
    {field, negated} =
      if String.starts_with?(token, "!") do
        {String.replace_prefix(token, "!", ""), true}
      else
        {token, false}
      end

    case String.split(field, ":", parts: 2) do
      [field_name, value] ->
        field_name = String.trim(field_name)
        value = String.trim(value) |> String.replace("\\ ", " ")

        {op, final_value} = parse_filter_value(negated, value)

        %{
          "field" => field_name,
          "op" => op,
          "value" => final_value
        }

      _ ->
        nil
    end
  end

  defp parse_filter_value(negated, value) do
    if String.contains?(value, "%") do
      op = if negated, do: "not_contains", else: "contains"
      unwrapped = unwrap_like(value)
      {op, unwrapped}
    else
      op = if negated, do: "not_equals", else: "equals"
      {op, value}
    end
  end

  defp unwrap_like("%" <> rest) do
    rest
    |> String.trim_trailing("%")
    |> String.replace("\\ ", " ")
  end

  defp unwrap_like(value), do: value

  defp update_builder(builder, params) do
    builder
    |> Map.merge(stringify_params(params))
    |> normalize_builder_filters()
  end

  defp stringify_params(params) do
    Map.new(params, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp normalize_builder_filters(builder) do
    config = Catalog.entity("devices")

    filters =
      builder
      |> Map.get("filters", %{})
      |> normalize_filters_list(config)

    Map.put(builder, "filters", filters)
  end

  defp normalize_filters_list(filters, config) when is_list(filters) do
    Enum.map(filters, fn filter ->
      %{
        "field" => normalize_filter_field(filter["field"], config),
        "op" => normalize_filter_op(filter["op"]),
        "value" => filter["value"] || ""
      }
    end)
  end

  defp normalize_filters_list(filters_by_index, config) when is_map(filters_by_index) do
    filters_by_index
    |> Enum.sort_by(fn {k, _} ->
      case Integer.parse(to_string(k)) do
        {i, ""} -> i
        _ -> 0
      end
    end)
    |> Enum.map(fn {_k, v} -> v end)
    |> normalize_filters_list(config)
  end

  defp normalize_filters_list(_, config) do
    [%{"field" => config.default_filter_field, "op" => "contains", "value" => ""}]
  end

  defp normalize_filter_field(nil, config), do: config.default_filter_field
  defp normalize_filter_field("", config), do: config.default_filter_field
  defp normalize_filter_field(field, _config), do: field

  defp normalize_filter_op(op) when op in ["contains", "not_contains", "equals", "not_equals"],
    do: op

  defp normalize_filter_op(_), do: "contains"

  defp build_target_query(builder) do
    filters = Map.get(builder, "filters", [])

    filters
    |> Enum.map(&build_filter_token/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp build_filter_token(%{"field" => field, "op" => op, "value" => value}) do
    field = String.trim(field || "")
    value = String.trim(value || "")

    if field == "" or value == "" do
      nil
    else
      escaped = String.replace(value, " ", "\\ ")

      case op do
        "equals" -> "#{field}:#{escaped}"
        "not_equals" -> "!#{field}:#{escaped}"
        "not_contains" -> "!#{field}:%#{escaped}%"
        _ -> "#{field}:%#{escaped}%"
      end
    end
  end

  defp build_filter_token(_), do: nil

  defp maybe_sync_builder_to_form(socket) do
    if socket.assigns.builder_sync do
      builder = socket.assigns.builder
      query = build_target_query(builder)

      ash_form =
        socket.assigns.ash_form
        |> Form.validate(%{"target_query" => query})

      scope = socket.assigns.current_scope
      device_count = count_target_devices(scope, query)

      socket
      |> assign(:ash_form, ash_form)
      |> assign(:form, to_form(ash_form))
      |> assign(:target_device_count, device_count)
    else
      socket
    end
  end
end
