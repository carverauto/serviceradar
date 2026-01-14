defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index do
  @moduledoc """
  LiveView for managing SNMP profiles configuration.

  Provides UI for:
  - SNMP Profiles: Admin-managed SNMP monitoring configuration profiles with SRQL targeting
  - SNMP Targets: Per-device SNMP connection settings
  - OID Templates: Vendor-based OID template library
  """
  use ServiceRadarWebNGWeb, :live_view

  require Ash.Query

  import ServiceRadarWebNGWeb.SettingsComponents
  import ServiceRadarWebNGWeb.QueryBuilderComponents

  alias AshPhoenix.Form
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadar.SNMPProfiles.SNMPTarget
  alias ServiceRadarWebNGWeb.SRQL.Catalog

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(:page_title, "SNMP Profiles")
      |> assign(:profiles, load_profiles(scope))
      |> assign(:selected_profile, nil)
      |> assign(:show_form, nil)
      |> assign(:ash_form, nil)
      |> assign(:form, nil)
      |> assign(:target_device_count, nil)
      |> assign(:builder_open, false)
      |> assign(:builder, default_builder_state())
      |> assign(:builder_sync, true)
      # Target modal state
      |> assign(:targets, [])
      |> assign(:show_target_modal, false)
      |> assign(:target_form, nil)
      |> assign(:editing_target, nil)
      |> assign(:show_password, false)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "SNMP Profiles")
    |> assign(:show_form, nil)
    |> assign(:ash_form, nil)
    |> assign(:form, nil)
    |> assign(:selected_profile, nil)
    |> assign(:builder_open, false)
    |> assign(:builder, default_builder_state())
    |> assign(:targets, [])
    |> assign(:show_target_modal, false)
    |> assign(:target_form, nil)
    |> assign(:editing_target, nil)
  end

  defp apply_action(socket, :new_profile, _params) do
    scope = socket.assigns.current_scope

    ash_form =
      Form.for_create(SNMPProfile, :create, domain: ServiceRadar.SNMPProfiles, scope: scope)

    socket
    |> assign(:page_title, "New SNMP Profile")
    |> assign(:show_form, :new_profile)
    |> assign(:ash_form, ash_form)
    |> assign(:form, to_form(ash_form))
    |> assign(:builder_open, false)
    |> assign(:builder, default_builder_state())
    |> assign(:builder_sync, true)
    |> assign(:target_device_count, nil)
    |> assign(:targets, [])
    |> assign(:show_target_modal, false)
    |> assign(:target_form, nil)
    |> assign(:editing_target, nil)
  end

  defp apply_action(socket, :edit_profile, %{"id" => id}) do
    case load_profile(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, "Profile not found")
        |> push_navigate(to: ~p"/settings/snmp")

      profile ->
        scope = socket.assigns.current_scope

        ash_form =
          Form.for_update(profile, :update, domain: ServiceRadar.SNMPProfiles, scope: scope)

        device_count = count_target_devices(scope, profile.target_query)

        # Parse the existing target_query into builder state if possible
        {builder, builder_sync} = parse_target_query_to_builder(profile.target_query)

        # Load targets for this profile
        targets = load_profile_targets(scope, profile.id)

        socket
        |> assign(:page_title, "Edit #{profile.name}")
        |> assign(:show_form, :edit_profile)
        |> assign(:selected_profile, profile)
        |> assign(:ash_form, ash_form)
        |> assign(:form, to_form(ash_form))
        |> assign(:target_device_count, device_count)
        |> assign(:builder_open, false)
        |> assign(:builder, builder)
        |> assign(:builder_sync, builder_sync)
        |> assign(:targets, targets)
        |> assign(:show_target_modal, false)
        |> assign(:target_form, nil)
        |> assign(:editing_target, nil)
    end
  end

  @impl true
  def handle_event("validate_profile", %{"form" => params}, socket) do
    scope = socket.assigns.current_scope
    target_query = Map.get(params, "target_query")
    device_count = count_target_devices(scope, target_query)
    ash_form = socket.assigns.ash_form |> Form.validate(params)

    {:noreply,
     socket
     |> assign(:ash_form, ash_form)
     |> assign(:form, to_form(ash_form))
     |> assign(:target_device_count, device_count)}
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
         |> push_navigate(to: ~p"/settings/snmp")}

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
    config = Catalog.entity("interfaces")

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

  # Target modal event handlers

  def handle_event("open_target_modal", _params, socket) do
    scope = socket.assigns.current_scope
    profile_id = socket.assigns.selected_profile.id

    target_form =
      Form.for_create(SNMPTarget, :create,
        domain: ServiceRadar.SNMPProfiles,
        scope: scope,
        params: %{snmp_profile_id: profile_id}
      )

    {:noreply,
     socket
     |> assign(:show_target_modal, true)
     |> assign(:target_form, to_form(target_form))
     |> assign(:editing_target, nil)
     |> assign(:show_password, false)}
  end

  def handle_event("edit_target", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case load_target(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Target not found")}

      target ->
        target_form =
          Form.for_update(target, :update, domain: ServiceRadar.SNMPProfiles, scope: scope)

        {:noreply,
         socket
         |> assign(:show_target_modal, true)
         |> assign(:target_form, to_form(target_form))
         |> assign(:editing_target, target)
         |> assign(:show_password, false)}
    end
  end

  def handle_event("close_target_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_target_modal, false)
     |> assign(:target_form, nil)
     |> assign(:editing_target, nil)
     |> assign(:show_password, false)}
  end

  def handle_event("toggle_password_visibility", _params, socket) do
    {:noreply, assign(socket, :show_password, !socket.assigns.show_password)}
  end

  def handle_event("validate_target", %{"form" => params}, socket) do
    scope = socket.assigns.current_scope

    target_form =
      if socket.assigns.editing_target do
        Form.for_update(socket.assigns.editing_target, :update,
          domain: ServiceRadar.SNMPProfiles,
          scope: scope
        )
      else
        profile_id = socket.assigns.selected_profile.id

        Form.for_create(SNMPTarget, :create,
          domain: ServiceRadar.SNMPProfiles,
          scope: scope,
          params: %{snmp_profile_id: profile_id}
        )
      end

    target_form = Form.validate(target_form, params)

    {:noreply, assign(socket, :target_form, to_form(target_form))}
  end

  def handle_event("save_target", %{"form" => params}, socket) do
    scope = socket.assigns.current_scope
    profile_id = socket.assigns.selected_profile.id

    target_form =
      if socket.assigns.editing_target do
        Form.for_update(socket.assigns.editing_target, :update,
          domain: ServiceRadar.SNMPProfiles,
          scope: scope
        )
      else
        Form.for_create(SNMPTarget, :create,
          domain: ServiceRadar.SNMPProfiles,
          scope: scope,
          params: %{snmp_profile_id: profile_id}
        )
      end

    target_form = Form.validate(target_form, params)

    case Form.submit(target_form, params: params) do
      {:ok, _target} ->
        action = if socket.assigns.editing_target, do: "updated", else: "created"
        targets = load_profile_targets(scope, profile_id)

        {:noreply,
         socket
         |> assign(:targets, targets)
         |> assign(:show_target_modal, false)
         |> assign(:target_form, nil)
         |> assign(:editing_target, nil)
         |> put_flash(:info, "Target #{action} successfully")}

      {:error, form} ->
        {:noreply, assign(socket, :target_form, to_form(form))}
    end
  end

  def handle_event("delete_target", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    profile_id = socket.assigns.selected_profile.id

    case load_target(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Target not found")}

      target ->
        case Ash.destroy(target, scope: scope) do
          :ok ->
            targets = load_profile_targets(scope, profile_id)

            {:noreply,
             socket
             |> assign(:targets, targets)
             |> put_flash(:info, "Target deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete target")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.settings_shell current_path="/settings/snmp">
      <.settings_nav current_path="/settings/snmp" />

      <div class="space-y-4">
        <!-- Content based on form state -->
        <%= if @show_form in [:new_profile, :edit_profile] do %>
          <.profile_form
            form={@form}
            show_form={@show_form}
            selected_profile={@selected_profile}
            target_device_count={@target_device_count}
            builder_open={@builder_open}
            builder={@builder}
            builder_sync={@builder_sync}
            targets={@targets}
          />
        <% else %>
          <.profiles_panel profiles={@profiles} />
        <% end %>
      </div>

      <!-- Target Modal -->
      <.target_modal
        :if={@show_target_modal}
        form={@target_form}
        editing_target={@editing_target}
        show_password={@show_password}
      />
    </.settings_shell>
    """
  end

  # Profiles Panel
  attr :profiles, :list, required: true

  defp profiles_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center justify-between w-full">
          <div>
            <div class="text-sm font-semibold">SNMP Profiles</div>
            <p class="text-xs text-base-content/60">
              {length(@profiles)} profile(s) configured
            </p>
          </div>
          <.link navigate={~p"/settings/snmp/new"}>
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
              <th>Poll Interval</th>
              <th>Targets</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@profiles == []}>
              <td colspan="6" class="text-center text-base-content/60 py-8">
                No SNMP profiles configured. Create one to start monitoring devices via SNMP.
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
                      navigate={~p"/settings/snmp/#{profile.id}/edit"}
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
                      <span class="text-base-content/60 italic">All unmatched interfaces</span>
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
                  {profile.poll_interval}s
                </td>
                <td>
                  <.ui_badge variant="ghost" size="xs">
                    0 targets
                  </.ui_badge>
                </td>
                <td>
                  <div class="flex items-center gap-1">
                    <.link navigate={~p"/settings/snmp/#{profile.id}/edit"}>
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
  attr :target_device_count, :integer, default: nil
  attr :builder_open, :boolean, default: false
  attr :builder, :map, default: %{}
  attr :builder_sync, :boolean, default: true
  attr :targets, :list, default: []

  defp profile_form(assigns) do
    is_default = assigns.selected_profile && assigns.selected_profile.is_default
    config = Catalog.entity("interfaces")

    assigns =
      assigns
      |> assign(:is_default, is_default)
      |> assign(:config, config)

    ~H"""
    <.ui_panel>
      <:header>
        <div class="text-sm font-semibold">
          {if @show_form == :new_profile,
            do: "New SNMP Profile",
            else: "Edit #{@selected_profile.name}"}
        </div>
      </:header>

      <.form
        for={@form}
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
                placeholder="e.g., Network Infrastructure"
                required
              />
            </div>
            <div>
              <label class="label"><span class="label-text">Poll Interval (seconds)</span></label>
              <.input
                type="number"
                field={@form[:poll_interval]}
                class="input input-bordered w-full"
                placeholder="60"
                min="10"
              />
            </div>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="label"><span class="label-text">Timeout (seconds)</span></label>
              <.input
                type="number"
                field={@form[:timeout]}
                class="input input-bordered w-full"
                placeholder="5"
                min="1"
              />
            </div>
            <div>
              <label class="label"><span class="label-text">Retries</span></label>
              <.input
                type="number"
                field={@form[:retries]}
                class="input input-bordered w-full"
                placeholder="3"
                min="0"
              />
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

        <!-- Interface Targeting Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Interface Targeting
          </h3>

          <%= if @is_default do %>
            <div class="bg-info/10 border border-info/30 rounded-lg p-4">
              <div class="flex items-start gap-3">
                <.icon name="hero-information-circle" class="size-5 text-info shrink-0 mt-0.5" />
                <div>
                  <p class="text-sm font-medium">Default Profile</p>
                  <p class="text-xs text-base-content/70 mt-1">
                    This is the default profile for your tenant. It will be applied to all interfaces
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
                      placeholder="e.g., in:interfaces type:ethernet device.hostname:%router%"
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
                    SRQL filters to match interfaces. Examples: <code class="bg-base-200 px-1 rounded">type:ethernet</code>, <code class="bg-base-200 px-1 rounded">device.hostname:%router%</code>
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
                        Match interfaces where:
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
                <.icon name="hero-signal" class="size-4 text-base-content/60" />
                <span class="text-sm">
                  <span class="font-semibold">{@target_device_count}</span>
                  <span class="text-base-content/60">interface(s) match this query</span>
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

        <!-- Actions -->
        <div class="flex justify-end gap-2 pt-4 border-t border-base-200">
          <.link navigate={~p"/settings/snmp"}>
            <.ui_button variant="ghost">Cancel</.ui_button>
          </.link>
          <.ui_button type="submit" variant="primary">
            {if @show_form == :new_profile, do: "Create Profile", else: "Save Changes"}
          </.ui_button>
        </div>
      </.form>

      <!-- SNMP Targets Section (only shown when editing) -->
      <div :if={@show_form == :edit_profile} class="mt-6 pt-6 border-t border-base-200">
        <div class="flex items-center justify-between mb-4">
          <div>
            <h3 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
              SNMP Targets
            </h3>
            <p class="text-xs text-base-content/50 mt-1">
              Network devices to poll with this profile
            </p>
          </div>
          <.ui_button
            variant="primary"
            size="sm"
            type="button"
            phx-click="open_target_modal"
          >
            <.icon name="hero-plus" class="size-4" /> Add Target
          </.ui_button>
        </div>

        <div :if={@targets == []} class="text-center py-8 text-base-content/60">
          <.icon name="hero-server-stack" class="size-10 mx-auto mb-2 opacity-50" />
          <p>No SNMP targets configured</p>
          <p class="text-xs mt-1">Add targets to start monitoring network devices via SNMP</p>
        </div>

        <div :if={@targets != []} class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr class="text-xs uppercase tracking-wide text-base-content/60">
                <th>Name</th>
                <th>Host</th>
                <th>Port</th>
                <th>Version</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= for target <- @targets do %>
                <tr class="hover:bg-base-200/40">
                  <td class="font-medium">{target.name}</td>
                  <td class="font-mono text-xs">{target.host}</td>
                  <td class="font-mono text-xs">{target.port}</td>
                  <td>
                    <.ui_badge variant={version_badge_variant(target.version)} size="xs">
                      {format_version(target.version)}
                    </.ui_badge>
                  </td>
                  <td>
                    <div class="flex items-center gap-1">
                      <.ui_button
                        variant="ghost"
                        size="xs"
                        type="button"
                        phx-click="edit_target"
                        phx-value-id={target.id}
                        title="Edit target"
                      >
                        <.icon name="hero-pencil" class="size-3" />
                      </.ui_button>
                      <.ui_button
                        variant="ghost"
                        size="xs"
                        type="button"
                        phx-click="delete_target"
                        phx-value-id={target.id}
                        data-confirm="Are you sure you want to delete this target?"
                        title="Delete target"
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
      </div>
    </.ui_panel>
    """
  end

  defp version_badge_variant(:v1), do: "ghost"
  defp version_badge_variant(:v2c), do: "info"
  defp version_badge_variant(:v3), do: "success"
  defp version_badge_variant(_), do: "ghost"

  defp format_version(:v1), do: "v1"
  defp format_version(:v2c), do: "v2c"
  defp format_version(:v3), do: "v3"
  defp format_version(v) when is_binary(v), do: v
  defp format_version(_), do: "v2c"

  # Target Modal
  attr :form, :any, required: true
  attr :editing_target, :any, default: nil
  attr :show_password, :boolean, default: false

  defp target_modal(assigns) do
    version = get_form_value(assigns.form, :version, "v2c")

    assigns = assign(assigns, :version, version)

    ~H"""
    <dialog id="target_modal" class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            type="button"
            phx-click="close_target_modal"
          >
            x
          </button>
        </form>

        <h3 class="font-bold text-lg mb-4">
          {if @editing_target, do: "Edit SNMP Target", else: "Add SNMP Target"}
        </h3>

        <.form
          for={@form}
          phx-submit="save_target"
          phx-change="validate_target"
          class="space-y-6"
        >
          <!-- Connection Settings -->
          <div class="space-y-4">
            <h4 class="text-sm font-semibold text-base-content/70">Connection</h4>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <label class="label"><span class="label-text">Target Name</span></label>
                <.input
                  type="text"
                  field={@form[:name]}
                  class="input input-bordered w-full"
                  placeholder="e.g., Core Router 1"
                  required
                />
              </div>
              <div>
                <label class="label"><span class="label-text">SNMP Version</span></label>
                <.input
                  type="select"
                  field={@form[:version]}
                  class="select select-bordered w-full"
                  options={[
                    {"SNMPv1", "v1"},
                    {"SNMPv2c", "v2c"},
                    {"SNMPv3", "v3"}
                  ]}
                />
              </div>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div class="md:col-span-2">
                <label class="label"><span class="label-text">Host</span></label>
                <.input
                  type="text"
                  field={@form[:host]}
                  class="input input-bordered w-full"
                  placeholder="e.g., 192.168.1.1 or router.local"
                  required
                />
              </div>
              <div>
                <label class="label"><span class="label-text">Port</span></label>
                <.input
                  type="number"
                  field={@form[:port]}
                  class="input input-bordered w-full"
                  placeholder="161"
                  min="1"
                  max="65535"
                />
              </div>
            </div>
          </div>

          <!-- Authentication based on version -->
          <div class="space-y-4">
            <h4 class="text-sm font-semibold text-base-content/70">Authentication</h4>

            <%= if @version in ["v1", "v2c"] do %>
              <!-- SNMPv1/v2c: Community String -->
              <div>
                <label class="label"><span class="label-text">Community String</span></label>
                <div class="flex items-center gap-2">
                  <.input
                    type={if @show_password, do: "text", else: "password"}
                    name="form[community]"
                    value=""
                    class="input input-bordered w-full"
                    placeholder={if @editing_target, do: "Enter new value to change", else: "e.g., public"}
                    autocomplete="off"
                  />
                  <.ui_icon_button
                    type="button"
                    phx-click="toggle_password_visibility"
                    title={if @show_password, do: "Hide", else: "Show"}
                  >
                    <.icon name={if @show_password, do: "hero-eye-slash", else: "hero-eye"} class="size-4" />
                  </.ui_icon_button>
                </div>
                <label class="label">
                  <span class="label-text-alt text-base-content/50">
                    <%= if @editing_target do %>
                      Leave blank to keep existing value
                    <% else %>
                      The community string is encrypted at rest
                    <% end %>
                  </span>
                </label>
              </div>
            <% else %>
              <!-- SNMPv3: Full authentication -->
              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div>
                  <label class="label"><span class="label-text">Username</span></label>
                  <.input
                    type="text"
                    field={@form[:username]}
                    class="input input-bordered w-full"
                    placeholder="e.g., snmpuser"
                  />
                </div>
                <div>
                  <label class="label"><span class="label-text">Security Level</span></label>
                  <.input
                    type="select"
                    field={@form[:security_level]}
                    class="select select-bordered w-full"
                    options={[
                      {"No Auth, No Privacy", "no_auth_no_priv"},
                      {"Auth, No Privacy", "auth_no_priv"},
                      {"Auth + Privacy", "auth_priv"}
                    ]}
                  />
                </div>
              </div>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div>
                  <label class="label"><span class="label-text">Auth Protocol</span></label>
                  <.input
                    type="select"
                    field={@form[:auth_protocol]}
                    class="select select-bordered w-full"
                    options={[
                      {"MD5", "md5"},
                      {"SHA", "sha"},
                      {"SHA-224", "sha224"},
                      {"SHA-256", "sha256"},
                      {"SHA-384", "sha384"},
                      {"SHA-512", "sha512"}
                    ]}
                  />
                </div>
                <div>
                  <label class="label"><span class="label-text">Auth Password</span></label>
                  <div class="flex items-center gap-2">
                    <.input
                      type={if @show_password, do: "text", else: "password"}
                      name="form[auth_password]"
                      value=""
                      class="input input-bordered w-full"
                      placeholder={if @editing_target, do: "Enter to change", else: "Auth password"}
                      autocomplete="off"
                    />
                    <.ui_icon_button
                      type="button"
                      phx-click="toggle_password_visibility"
                      title={if @show_password, do: "Hide", else: "Show"}
                    >
                      <.icon name={if @show_password, do: "hero-eye-slash", else: "hero-eye"} class="size-4" />
                    </.ui_icon_button>
                  </div>
                </div>
              </div>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div>
                  <label class="label"><span class="label-text">Privacy Protocol</span></label>
                  <.input
                    type="select"
                    field={@form[:priv_protocol]}
                    class="select select-bordered w-full"
                    options={[
                      {"DES", "des"},
                      {"AES", "aes"},
                      {"AES-192", "aes192"},
                      {"AES-256", "aes256"}
                    ]}
                  />
                </div>
                <div>
                  <label class="label"><span class="label-text">Privacy Password</span></label>
                  <.input
                    type={if @show_password, do: "text", else: "password"}
                    name="form[priv_password]"
                    value=""
                    class="input input-bordered w-full"
                    placeholder={if @editing_target, do: "Enter to change", else: "Privacy password"}
                    autocomplete="off"
                  />
                </div>
              </div>

              <p class="text-xs text-base-content/50">
                <%= if @editing_target do %>
                  Leave password fields blank to keep existing values. Credentials are encrypted at rest.
                <% else %>
                  All passwords are encrypted at rest using AES-256-GCM.
                <% end %>
              </p>
            <% end %>
          </div>

          <!-- Modal Actions -->
          <div class="modal-action">
            <.ui_button type="button" variant="ghost" phx-click="close_target_modal">
              Cancel
            </.ui_button>
            <.ui_button type="submit" variant="primary">
              {if @editing_target, do: "Save Changes", else: "Add Target"}
            </.ui_button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="close_target_modal">close</button>
      </form>
    </dialog>
    """
  end

  defp get_form_value(form, field, default) do
    case form[field] do
      %Phoenix.HTML.FormField{value: value} when not is_nil(value) ->
        to_string(value)

      _ ->
        default
    end
  end

  # Helper Functions

  defp load_profiles(scope) do
    case Ash.read(SNMPProfile, scope: scope) do
      {:ok, profiles} ->
        # Sort by priority (highest first), then by name
        profiles
        |> Enum.sort_by(fn p -> {-p.priority, p.name} end)

      {:error, _} ->
        []
    end
  end

  defp load_profile(scope, id) do
    case Ash.get(SNMPProfile, id, scope: scope) do
      {:ok, profile} -> profile
      {:error, _} -> nil
    end
  end

  defp load_profile_targets(scope, profile_id) do
    query =
      SNMPTarget
      |> Ash.Query.filter(snmp_profile_id == ^profile_id)
      |> Ash.Query.sort(:name)

    case Ash.read(query, scope: scope) do
      {:ok, targets} -> targets
      {:error, _} -> []
    end
  end

  defp load_target(scope, id) do
    case Ash.get(SNMPTarget, id, scope: scope) do
      {:ok, target} -> target
      {:error, _} -> nil
    end
  end

  defp count_target_devices(_scope, nil), do: nil
  defp count_target_devices(_scope, ""), do: nil

  defp count_target_devices(_scope, _target_query) do
    # TODO: Implement interface counting from SRQL query
    # For now, return nil to hide the count
    nil
  end

  # Builder Helper Functions

  defp default_builder_state do
    config = Catalog.entity("interfaces")

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
    config = Catalog.entity("interfaces")

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
