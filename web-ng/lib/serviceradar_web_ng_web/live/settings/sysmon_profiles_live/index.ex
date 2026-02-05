defmodule ServiceRadarWebNGWeb.Settings.SysmonProfilesLive.Index do
  @moduledoc """
  LiveView for managing sysmon profiles configuration.

  Provides UI for:
  - Host Health Profiles: Admin-managed monitoring configuration profiles with SRQL targeting
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents
  import ServiceRadarWebNGWeb.QueryBuilderComponents

  alias AshPhoenix.Form
  alias ServiceRadar.AgentConfig.ConfigServer
  alias ServiceRadar.AgentConfig.Compilers.SysmonCompiler
  alias ServiceRadar.SysmonProfiles.SysmonProfile
  alias ServiceRadarWebNGWeb.SRQL.Catalog

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(:page_title, "Host Health Profiles")
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
    |> assign(:page_title, "Host Health Profiles")
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
    |> assign(:page_title, "New Host Health Profile")
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
    params = transform_array_fields(params)
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
    params = transform_array_fields(params)
    ash_form = socket.assigns.ash_form |> Form.validate(params)
    scope = socket.assigns.current_scope

    case Form.submit(ash_form, params: params) do
      {:ok, _profile} ->
        action = if socket.assigns.show_form == :new_profile, do: "created", else: "updated"
        _ = ConfigServer.invalidate(:sysmon)

        {:noreply,
         socket
         |> assign(:profiles, load_profiles(scope))
         |> put_flash(:info, "Profile #{action}. Pushed config to connected agents.")
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
            _ = ConfigServer.invalidate(:sysmon)

            {:noreply,
             socket
             |> assign(:profiles, load_profiles(scope))
             |> put_flash(
               :info,
               "Profile #{if new_enabled, do: "enabled", else: "disabled"}. Pushed config to connected agents."
             )}

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

      profile ->
        case Ash.destroy(profile, scope: scope) do
          :ok ->
            _ = ConfigServer.invalidate(:sysmon)

            {:noreply,
             socket
             |> assign(:profiles, load_profiles(scope))
             |> put_flash(:info, "Profile deleted. Pushed config to connected agents.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete profile")}
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
      |> assign(:builder_sync, true)
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
      |> assign(:builder_sync, true)
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
      |> assign(:builder_sync, true)
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
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path="/settings/sysmon">
        <.settings_nav current_path="/settings/sysmon" current_scope={@current_scope} />
        <.agents_nav current_path="/settings/sysmon" />

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
    </Layouts.app>
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
            <div class="text-sm font-semibold">Host Health Profiles</div>
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
                  </div>
                  <p :if={profile.description} class="text-xs text-base-content/60 truncate max-w-xs">
                    {profile.description}
                  </p>
                </td>
                <td class="text-xs max-w-xs">
                  <%= if profile.target_query && profile.target_query != "" do %>
                    <code
                      class="font-mono text-[11px] bg-base-200/50 px-1.5 py-0.5 rounded truncate block max-w-[200px]"
                      title={profile.target_query}
                    >
                      {profile.target_query}
                    </code>
                  <% else %>
                    <span class="text-base-content/40">No targeting (will not match devices)</span>
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
    config = Catalog.entity("devices")

    assigns =
      assigns
      |> assign(:config, config)

    ~H"""
    <.ui_panel>
      <:header>
        <div class="text-sm font-semibold">
          {if @show_form == :new_profile,
            do: "New Host Health Profile",
            else: "Edit #{@selected_profile.name}"}
        </div>
      </:header>

      <form id="sysmon-builder-form" phx-change="builder_change" phx-debounce="200"></form>

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
                            form="sysmon-builder-form"
                            class="w-40 placeholder:text-base-content/40"
                          />
                        <% else %>
                          <.ui_inline_select
                            name={"builder[filters][#{idx}][field]"}
                            form="sysmon-builder-form"
                          >
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
                          form="sysmon-builder-form"
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
                          form="sysmon-builder-form"
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
            <label class="label">
              <span class="label-text">Mount Points to Monitor (optional)</span>
            </label>
            <.input
              type="text"
              field={@form[:disk_paths]}
              class="input input-bordered w-full"
              placeholder="/, /data, /var"
            />
            <label class="label">
              <span class="label-text-alt text-base-content/50">
                Leave empty to collect all disks. Use a comma-separated list to restrict collection.
              </span>
            </label>
          </div>
        </div>
        
    <!-- Disk Excludes Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Disk Excludes
          </h3>

          <div>
            <label class="label"><span class="label-text">Mount Points to Exclude</span></label>
            <.input
              type="text"
              field={@form[:disk_exclude_paths]}
              class="input input-bordered w-full"
              placeholder="/var/lib/docker, /var/lib/kubelet"
            />
            <label class="label">
              <span class="label-text-alt text-base-content/50">
                Comma-separated list of mount points to ignore when collecting all disks.
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
    srql_module = srql_module()
    query = String.trim(target_query)

    full_query =
      cond do
        query == "" ->
          ~s|in:devices stats:"count() as total"|

        String.starts_with?(query, "in:") ->
          ~s|#{query} stats:"count() as total"|

        true ->
          ~s|in:devices #{query} stats:"count() as total"|
      end

    case srql_module.query(full_query, %{scope: scope}) do
      {:ok, %{"results" => [%{"total" => count} | _]}} when is_integer(count) ->
        count

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
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

        {op, final_value} = parse_filter_value(field_name, negated, value)

        %{
          "field" => field_name,
          "op" => op,
          "value" => final_value
        }

      _ ->
        nil
    end
  end

  defp parse_filter_value(field, negated, value) do
    cond do
      list_filter_field?(field) ->
        normalized = normalize_list_value(value) |> Enum.join(", ")
        {maybe_negate_op("equals", negated), normalized}

      String.contains?(value, "%") ->
        {maybe_negate_op("contains", negated), unwrap_like(value)}

      true ->
        {maybe_negate_op("equals", negated), value}
    end
  end

  defp maybe_negate_op("equals", true), do: "not_equals"
  defp maybe_negate_op("contains", true), do: "not_contains"
  defp maybe_negate_op(op, _), do: op

  defp unwrap_like("%" <> rest) do
    rest
    |> String.trim_trailing("%")
    |> String.replace("\\ ", " ")
  end

  defp unwrap_like(value), do: value

  defp list_filter_field?(field) when is_binary(field) do
    field in ["discovery_sources"]
  end

  defp list_filter_field?(_), do: false

  defp normalize_list_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("(")
    |> String.trim_trailing(")")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_list_value(value) when is_list(value) do
    value
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_list_value(_), do: []

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
      field = normalize_filter_field(filter["field"], config)

      %{
        "field" => field,
        "op" => normalize_filter_op(filter["op"], field),
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

  defp normalize_filter_op(op, field) do
    if list_filter_field?(field) do
      case op do
        "not_equals" -> "not_equals"
        "not_contains" -> "not_equals"
        "equals" -> "equals"
        "contains" -> "equals"
        _ -> "equals"
      end
    else
      case op do
        "contains" -> "contains"
        "not_contains" -> "not_contains"
        "equals" -> "equals"
        "not_equals" -> "not_equals"
        _ -> "contains"
      end
    end
  end

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

    cond do
      field == "" or value == "" ->
        nil

      list_filter_field?(field) ->
        build_list_filter_token(field, op, value)

      true ->
        build_scalar_filter_token(field, op, value)
    end
  end

  defp build_filter_token(_), do: nil

  defp build_list_filter_token(field, op, value) do
    values =
      value
      |> normalize_list_value()
      |> Enum.map(&String.replace(&1, " ", "\\ "))

    token = Enum.join(values, ",")

    case op do
      "not_equals" -> "!#{field}:(#{token})"
      "not_contains" -> "!#{field}:(#{token})"
      _ -> "#{field}:(#{token})"
    end
  end

  defp build_scalar_filter_token(field, op, value) do
    escaped = String.replace(value, " ", "\\ ")

    case op do
      "equals" -> "#{field}:#{escaped}"
      "not_equals" -> "!#{field}:#{escaped}"
      "not_contains" -> "!#{field}:%#{escaped}%"
      _ -> "#{field}:%#{escaped}%"
    end
  end

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

  # Transform comma-separated string fields to arrays for Ash
  defp transform_array_fields(params) do
    params
    |> transform_csv_to_array("disk_paths")
    |> transform_csv_to_array("disk_exclude_paths")
  end

  defp transform_csv_to_array(params, field) do
    case Map.get(params, field) do
      nil ->
        params

      "" ->
        Map.put(params, field, [])

      value when is_binary(value) ->
        array =
          value
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        Map.put(params, field, array)

      value when is_list(value) ->
        params

      _ ->
        params
    end
  end
end
