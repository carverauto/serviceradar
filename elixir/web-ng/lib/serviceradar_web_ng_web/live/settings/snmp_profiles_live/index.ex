defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index do
  @moduledoc """
  LiveView for managing SNMP profiles configuration.

  ## Architecture (v2)

  SNMP profiles now use a cleaner SRQL-based model:
  - **Target Query (SRQL)**: Dynamically matches devices/interfaces from inventory
  - **OID Templates**: Select which metrics to poll via reusable template collections
  - **Credentials**: Profile-level fallback, with per-device overrides via DeviceSNMPCredential

  Legacy manual SNMPTarget configuration is deprecated but shown read-only for existing profiles.

  Provides UI for:
  - SNMP Profiles: Admin-managed SNMP monitoring configuration profiles with SRQL targeting
  - OID Template Selection: Choose which metrics to poll from matched devices
  - OID Templates: Vendor-based OID template library (builtin + custom)
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.QueryBuilderComponents
  import ServiceRadarWebNGWeb.SettingsComponents

  alias AshPhoenix.Form
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.SNMPProfiles.BuiltinTemplates
  alias ServiceRadar.SNMPProfiles.SNMPOIDConfig
  alias ServiceRadar.SNMPProfiles.SNMPOIDTemplate
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadar.SNMPProfiles.SNMPTarget
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.SRQL.Catalog

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.snmp_profiles.manage") do
      {profiles, profile_target_counts} = load_profiles_with_counts(scope)

      socket =
        socket
        |> assign(:page_title, "SNMP Profiles")
        |> assign(:profiles, profiles)
        |> assign(:profile_target_counts, profile_target_counts)
        |> assign(:selected_profile, nil)
        |> assign(:show_form, nil)
        |> assign(:ash_form, nil)
        |> assign(:form, nil)
        |> assign(:target_device_count, nil)
        |> assign(:target_entity, "devices")
        |> assign(:builder_open, false)
        |> assign(:builder, default_builder_state())
        |> assign(:builder_sync, true)
        # Target modal state
        |> assign(:targets, [])
        |> assign(:show_target_modal, false)
        |> assign(:target_form, nil)
        |> assign(:editing_target, nil)
        |> assign(:show_password, false)
        |> assign(:test_connection_result, nil)
        |> assign(:test_connection_loading, false)
        # OID management state
        |> assign(:target_oids, [])
        |> assign(:show_template_browser, false)
        |> assign(:template_search, "")
        |> assign(:selected_vendor, "standard")
        # Custom template modal state
        |> assign(:show_custom_template_modal, false)
        |> assign(:custom_template_form, nil)
        |> assign(:custom_template_oids, [])
        |> assign(:editing_custom_template, nil)
        |> assign(:custom_templates, load_custom_templates(scope))
        # OID template selection state (for profile form)
        |> assign(:available_templates, load_all_templates(scope))
        |> assign(:selected_template_ids, [])

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "You do not have access to SNMP profiles")
       |> push_navigate(to: ~p"/settings/profile")}
    end
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
    |> assign(:target_oids, [])
    |> assign(:show_template_browser, false)
    |> assign(:selected_template_ids, [])
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
    |> assign(:target_entity, "devices")
    |> assign(:targets, [])
    |> assign(:show_target_modal, false)
    |> assign(:target_form, nil)
    |> assign(:editing_target, nil)
    |> assign(:target_oids, [])
    |> assign(:show_template_browser, false)
    |> assign(:selected_template_ids, [])
    |> assign_target_preview(nil)
  end

  defp apply_action(socket, :edit_profile, %{"id" => id}) do
    case load_profile(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, "Profile not found")
        |> push_navigate(to: ~p"/settings/snmp")

      profile ->
        scope = socket.assigns.current_scope
        target_query = resolve_target_query(profile.target_query, profile.is_default)
        normalized_query = normalize_target_query(target_query, profile.is_default)

        ash_form =
          profile
          |> Form.for_update(:update, domain: ServiceRadar.SNMPProfiles, scope: scope)
          |> maybe_set_target_query(target_query)

        {device_count, target_entity} =
          if is_nil(normalized_query) do
            {nil, "devices"}
          else
            {count_target_devices(scope, normalized_query), extract_srql_entity(normalized_query)}
          end

        # Parse the existing target_query into builder state if possible
        {builder, builder_sync} = parse_target_query_to_builder(target_query)

        # Load targets for this profile (legacy, for display only)
        targets = load_profile_targets(scope, profile.id)

        # Load profile's selected OID templates
        selected_template_ids = profile.oid_template_ids || []

        socket
        |> assign(:page_title, "Edit #{profile.name}")
        |> assign(:show_form, :edit_profile)
        |> assign(:selected_profile, profile)
        |> assign(:ash_form, ash_form)
        |> assign(:form, to_form(ash_form))
        |> assign(:target_device_count, device_count)
        |> assign(:target_entity, target_entity)
        |> assign(:builder_open, false)
        |> assign(:builder, builder)
        |> assign(:builder_sync, builder_sync)
        |> assign(:targets, targets)
        |> assign(:selected_template_ids, selected_template_ids)
        |> assign(:show_target_modal, false)
        |> assign(:target_form, nil)
        |> assign(:editing_target, nil)
        |> assign(:target_oids, [])
        |> assign(:show_template_browser, false)
    end
  end

  @impl true
  def handle_event("validate_profile", %{"form" => params}, socket) do
    target_query = Map.get(params, "target_query")
    ash_form = Form.validate(socket.assigns.ash_form, params)

    {:noreply,
     socket
     |> assign(:ash_form, ash_form)
     |> assign(:form, to_form(ash_form))
     |> assign_target_preview(target_query)}
  end

  def handle_event("save_profile", %{"form" => params}, socket) do
    params =
      if socket.assigns.show_form == :edit_profile do
        sensitive_fields = ["community", "auth_password", "priv_password"]

        Map.reject(params, fn {key, value} ->
          key in sensitive_fields and value == ""
        end)
      else
        params
      end

    # Include selected OID template IDs
    params = Map.put(params, "oid_template_ids", socket.assigns.selected_template_ids)

    ash_form = Form.validate(socket.assigns.ash_form, params)
    scope = socket.assigns.current_scope

    case Form.submit(ash_form, params: params) do
      {:ok, _profile} ->
        action = if socket.assigns.show_form == :new_profile, do: "created", else: "updated"

        {:noreply,
         socket
         |> assign_profiles_with_counts(scope)
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
             |> assign_profiles_with_counts(scope)
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
             |> assign_profiles_with_counts(scope)
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
        case profile
             |> Ash.Changeset.for_update(:set_as_default, %{})
             |> Ash.update(scope: scope) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> assign_profiles_with_counts(scope)
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
    ash_form = Form.validate(socket.assigns.ash_form, %{"target_query" => query})

    {:noreply,
     socket
     |> assign(:ash_form, ash_form)
     |> assign(:form, to_form(ash_form))
     |> assign(:builder_sync, true)
     |> assign_target_preview(query)}
  end

  # OID Template Selection event handlers

  def handle_event("toggle_template", %{"id" => template_id}, socket) do
    current_ids = socket.assigns.selected_template_ids

    new_ids =
      if template_id in current_ids do
        Enum.reject(current_ids, &(&1 == template_id))
      else
        current_ids ++ [template_id]
      end

    {:noreply, assign(socket, :selected_template_ids, new_ids)}
  end

  def handle_event("remove_template", %{"id" => template_id}, socket) do
    new_ids = Enum.reject(socket.assigns.selected_template_ids, &(&1 == template_id))
    {:noreply, assign(socket, :selected_template_ids, new_ids)}
  end

  # Target modal event handlers (legacy)

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
     |> assign(:show_password, false)
     |> assign(:target_oids, [])
     |> assign(:show_template_browser, false)
     |> assign(:test_connection_result, nil)
     |> assign(:test_connection_loading, false)}
  end

  def handle_event("edit_target", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case load_target(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Target not found")}

      target ->
        target_form =
          Form.for_update(target, :update, domain: ServiceRadar.SNMPProfiles, scope: scope)

        # Load existing OIDs for this target
        oids = load_target_oids(scope, target.id)

        {:noreply,
         socket
         |> assign(:show_target_modal, true)
         |> assign(:target_form, to_form(target_form))
         |> assign(:editing_target, target)
         |> assign(:show_password, false)
         |> assign(:target_oids, oids)
         |> assign(:show_template_browser, false)
         |> assign(:test_connection_result, nil)
         |> assign(:test_connection_loading, false)}
    end
  end

  def handle_event("close_target_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_target_modal, false)
     |> assign(:target_form, nil)
     |> assign(:editing_target, nil)
     |> assign(:show_password, false)
     |> assign(:target_oids, [])
     |> assign(:show_template_browser, false)
     |> assign(:test_connection_result, nil)
     |> assign(:test_connection_loading, false)}
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

    # When editing, remove blank password/community fields from params
    # to avoid accidentally clearing existing encrypted credentials.
    params =
      if socket.assigns.editing_target do
        sensitive_fields = ["community", "auth_password", "priv_password"]

        Map.reject(params, fn {key, value} ->
          key in sensitive_fields and value == ""
        end)
      else
        params
      end

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

  def handle_event("test_connection", _params, socket) do
    form = socket.assigns.target_form

    # Get form values - handle both source formats
    host = get_form_value(form, :host, "")
    port = get_form_value(form, :port, 161)

    # Convert port to integer if needed
    port =
      case port do
        p when is_integer(p) ->
          p

        p when is_binary(p) ->
          case Integer.parse(p) do
            {int, _} -> int
            :error -> 161
          end

        _ ->
          161
      end

    # Validate we have a host
    if host == "" do
      {:noreply,
       assign(socket, :test_connection_result, %{
         success: false,
         message: "Please enter a host address first"
       })}
    else
      # Set loading state
      socket = assign(socket, :test_connection_loading, true)

      # Send to self to do async work
      send(self(), {:test_snmp_connection, host, port})

      {:noreply, socket}
    end
  end

  # OID management event handlers

  def handle_event("add_oid", _params, socket) do
    new_oid = %{
      "oid" => "",
      "name" => "",
      "data_type" => "gauge",
      "scale" => "1.0",
      "delta" => false,
      "temp_id" => System.unique_integer([:positive])
    }

    oids = socket.assigns.target_oids ++ [new_oid]
    {:noreply, assign(socket, :target_oids, oids)}
  end

  def handle_event("remove_oid", %{"index" => index_str}, socket) do
    index =
      case Integer.parse(index_str) do
        {n, _} -> n
        _ -> nil
      end

    if index do
      oids = List.delete_at(socket.assigns.target_oids, index)
      {:noreply, assign(socket, :target_oids, oids)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_oid", %{"index" => index_str, "field" => field} = params, socket) do
    index =
      case Integer.parse(index_str) do
        {n, _} -> n
        _ -> nil
      end

    if index do
      oids = socket.assigns.target_oids
      current_oid = Enum.at(oids, index)

      # Get the new value for the changed field
      # - For text inputs (phx-blur): fresh value is in params["value"]
      # - For select (phx-change): fresh value is in params["value"]
      # - For checkbox (phx-click): toggled value is in params["delta"]
      new_value =
        case field do
          "delta" -> Map.get(params, "delta", "false") == "true"
          _ -> Map.get(params, "value", "")
        end

      updated_oid = Map.put(current_oid, field, new_value)
      updated_oids = List.replace_at(oids, index, updated_oid)
      {:noreply, assign(socket, :target_oids, updated_oids)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_template_browser", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_template_browser, true)
     |> assign(:template_search, "")
     |> assign(:selected_vendor, "standard")}
  end

  def handle_event("close_template_browser", _params, socket) do
    {:noreply, assign(socket, :show_template_browser, false)}
  end

  def handle_event("select_vendor", %{"vendor" => vendor}, socket) do
    {:noreply, assign(socket, :selected_vendor, vendor)}
  end

  def handle_event("search_templates", %{"search" => search}, socket) do
    {:noreply, assign(socket, :template_search, search)}
  end

  def handle_event("add_template_oids", %{"template_id" => template_id}, socket) do
    templates = BuiltinTemplates.all_templates()

    case Enum.find(templates, &(&1.id == template_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Template not found")}

      template ->
        # Convert template OIDs to our working format
        new_oids =
          Enum.map(template.oids, fn oid ->
            %{
              "oid" => oid.oid,
              "name" => oid.name,
              "data_type" => to_string(oid.data_type),
              "scale" => to_string(oid.scale || 1.0),
              "delta" => oid.delta || false,
              "temp_id" => System.unique_integer([:positive])
            }
          end)

        # Add to existing OIDs (avoiding duplicates by OID string)
        existing_oid_strings = Enum.map(socket.assigns.target_oids, & &1["oid"])

        unique_new_oids =
          Enum.reject(new_oids, fn oid -> oid["oid"] in existing_oid_strings end)

        updated_oids = socket.assigns.target_oids ++ unique_new_oids

        {:noreply,
         socket
         |> assign(:target_oids, updated_oids)
         |> assign(:show_template_browser, false)
         |> put_flash(:info, "Added #{length(unique_new_oids)} OID(s) from #{template.name}")}
    end
  end

  def handle_event("add_custom_template_oids", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Ash.get(SNMPOIDTemplate, id, scope: scope) do
      {:ok, template} ->
        # Convert template OIDs to our working format
        new_oids =
          Enum.map(template.oids || [], fn oid ->
            %{
              "oid" => Map.get(oid, "oid", ""),
              "name" => Map.get(oid, "name", ""),
              "data_type" => Map.get(oid, "data_type", "gauge"),
              "scale" => to_string(Map.get(oid, "scale", 1.0)),
              "delta" => Map.get(oid, "delta", false),
              "temp_id" => System.unique_integer([:positive])
            }
          end)

        # Add to existing OIDs (avoiding duplicates by OID string)
        existing_oid_strings = Enum.map(socket.assigns.target_oids, & &1["oid"])

        unique_new_oids =
          Enum.reject(new_oids, fn oid -> oid["oid"] in existing_oid_strings end)

        updated_oids = socket.assigns.target_oids ++ unique_new_oids

        {:noreply,
         socket
         |> assign(:target_oids, updated_oids)
         |> assign(:show_template_browser, false)
         |> put_flash(:info, "Added #{length(unique_new_oids)} OID(s) from #{template.name}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Template not found")}
    end
  end

  def handle_event("copy_template_to_custom", %{"template_id" => template_id}, socket) do
    templates = BuiltinTemplates.all_templates()
    scope = socket.assigns.current_scope

    case Enum.find(templates, &(&1.id == template_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Template not found")}

      template ->
        # Create a custom copy of the built-in template
        # Convert OIDs to the expected format for SNMPOIDTemplate
        oids =
          Enum.map(template.oids, fn oid ->
            %{
              "oid" => oid.oid,
              "name" => oid.name,
              "data_type" => to_string(oid.data_type),
              "scale" => oid.scale || 1.0,
              "delta" => oid.delta || false
            }
          end)

        attrs = %{
          name: "#{template.name} (Copy)",
          description: template.description,
          vendor: "custom",
          category: template.category,
          oids: oids
        }

        case create_custom_template(scope, attrs) do
          {:ok, custom_template} ->
            {:noreply, put_flash(socket, :info, "Created custom template: #{custom_template.name}")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to create custom template")}
        end
    end
  end

  # Custom Template Modal Event Handlers

  def handle_event("open_custom_template_modal", _params, socket) do
    scope = socket.assigns.current_scope

    ash_form =
      Form.for_create(SNMPOIDTemplate, :create, domain: ServiceRadar.SNMPProfiles, scope: scope)

    {:noreply,
     socket
     |> assign(:show_custom_template_modal, true)
     |> assign(:custom_template_form, to_form(ash_form))
     |> assign(:custom_template_oids, [])
     |> assign(:editing_custom_template, nil)
     |> assign(:ash_custom_template_form, ash_form)}
  end

  def handle_event("edit_custom_template", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Ash.get(SNMPOIDTemplate, id, scope: scope) do
      {:ok, template} ->
        ash_form =
          Form.for_update(template, :update, domain: ServiceRadar.SNMPProfiles, scope: scope)

        # Convert OIDs to UI format
        oids =
          Enum.map(template.oids || [], fn oid ->
            %{
              "oid" => Map.get(oid, "oid", ""),
              "name" => Map.get(oid, "name", ""),
              "data_type" => Map.get(oid, "data_type", "gauge"),
              "scale" => to_string(Map.get(oid, "scale", 1.0)),
              "delta" => Map.get(oid, "delta", false),
              "temp_id" => System.unique_integer([:positive])
            }
          end)

        {:noreply,
         socket
         |> assign(:show_custom_template_modal, true)
         |> assign(:custom_template_form, to_form(ash_form))
         |> assign(:custom_template_oids, oids)
         |> assign(:editing_custom_template, template)
         |> assign(:ash_custom_template_form, ash_form)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Template not found")}
    end
  end

  def handle_event("close_custom_template_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_custom_template_modal, false)
     |> assign(:custom_template_form, nil)
     |> assign(:custom_template_oids, [])
     |> assign(:editing_custom_template, nil)
     |> assign(:ash_custom_template_form, nil)}
  end

  def handle_event("validate_custom_template", %{"form" => params}, socket) do
    ash_form = Form.validate(socket.assigns.ash_custom_template_form, params)

    {:noreply,
     socket
     |> assign(:custom_template_form, to_form(ash_form))
     |> assign(:ash_custom_template_form, ash_form)}
  end

  def handle_event("save_custom_template", %{"form" => params}, socket) do
    scope = socket.assigns.current_scope
    oids = socket.assigns.custom_template_oids

    # Convert OIDs to the format expected by the resource
    oids_data =
      oids
      |> Enum.map(fn oid ->
        %{
          "oid" => Map.get(oid, "oid", ""),
          "name" => Map.get(oid, "name", ""),
          "data_type" => Map.get(oid, "data_type", "gauge"),
          "scale" => parse_float(Map.get(oid, "scale", "1.0")),
          "delta" => Map.get(oid, "delta", false)
        }
      end)
      |> Enum.reject(fn oid -> oid["oid"] == "" end)

    # Merge OIDs into params
    params = Map.put(params, "oids", oids_data)
    # Ensure vendor is set to "custom"
    params = Map.put(params, "vendor", "custom")

    ash_form = Form.validate(socket.assigns.ash_custom_template_form, params)

    case Form.submit(ash_form, params: params) do
      {:ok, template} ->
        action = if socket.assigns.editing_custom_template, do: "updated", else: "created"

        {:noreply,
         socket
         |> assign(:show_custom_template_modal, false)
         |> assign(:custom_template_form, nil)
         |> assign(:custom_template_oids, [])
         |> assign(:editing_custom_template, nil)
         |> assign(:ash_custom_template_form, nil)
         |> assign(:custom_templates, load_custom_templates(scope))
         |> put_flash(:info, "Template #{action}: #{template.name}")}

      {:error, ash_form} ->
        {:noreply,
         socket
         |> assign(:custom_template_form, to_form(ash_form))
         |> assign(:ash_custom_template_form, ash_form)
         |> put_flash(:error, "Failed to save template")}
    end
  end

  def handle_event("delete_custom_template", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Ash.get(SNMPOIDTemplate, id, scope: scope) do
      {:ok, template} ->
        case Ash.destroy(template, scope: scope) do
          :ok ->
            {:noreply,
             socket
             |> assign(:custom_templates, load_custom_templates(scope))
             |> put_flash(:info, "Template deleted: #{template.name}")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete template")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Template not found")}
    end
  end

  # Custom template OID management
  def handle_event("add_template_oid", _params, socket) do
    new_oid = %{
      "oid" => "",
      "name" => "",
      "data_type" => "gauge",
      "scale" => "1.0",
      "delta" => false,
      "temp_id" => System.unique_integer([:positive])
    }

    oids = socket.assigns.custom_template_oids ++ [new_oid]
    {:noreply, assign(socket, :custom_template_oids, oids)}
  end

  def handle_event("remove_template_oid", %{"index" => index_str}, socket) do
    index =
      case Integer.parse(index_str) do
        {n, _} -> n
        _ -> nil
      end

    if index do
      oids = List.delete_at(socket.assigns.custom_template_oids, index)
      {:noreply, assign(socket, :custom_template_oids, oids)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_template_oid", %{"index" => index_str, "field" => field} = params, socket) do
    index =
      case Integer.parse(index_str) do
        {n, _} -> n
        _ -> nil
      end

    if index do
      oids = socket.assigns.custom_template_oids
      current_oid = Enum.at(oids, index)

      # Get the new value for the changed field
      # - For text inputs (phx-blur): fresh value is in params["value"]
      # - For select (phx-change): fresh value is in params["value"]
      # - For checkbox (phx-click): toggled value is in params["delta"]
      new_value =
        case field do
          "delta" -> Map.get(params, "delta", "false") == "true"
          _ -> Map.get(params, "value", "")
        end

      updated_oid = Map.put(current_oid, field, new_value)
      updated_oids = List.replace_at(oids, index, updated_oid)
      {:noreply, assign(socket, :custom_template_oids, updated_oids)}
    else
      {:noreply, socket}
    end
  end

  # Handle info callbacks

  @impl true
  def handle_info({:test_snmp_connection, host, port}, socket) do
    result = test_snmp_connectivity(host, port)

    {:noreply,
     socket
     |> assign(:test_connection_loading, false)
     |> assign(:test_connection_result, result)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Private helper functions

  defp create_custom_template(scope, attrs) do
    SNMPOIDTemplate
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create(scope: scope)
  end

  # Test SNMP connectivity by resolving the host and sending a UDP probe
  # Note: SNMP uses UDP, so we can't use TCP connection tests
  defp test_snmp_connectivity(host, port) do
    # First, resolve the hostname to verify it exists
    host_charlist = String.to_charlist(host)

    case :inet.getaddr(host_charlist, :inet) do
      {:ok, ip_addr} ->
        # Host resolved successfully, now try UDP reachability test
        test_udp_reachability(host, ip_addr, port)

      {:error, :nxdomain} ->
        %{
          success: false,
          message: "Host not found - check the hostname"
        }

      {:error, :einval} ->
        %{
          success: false,
          message: "Invalid host address format"
        }

      {:error, reason} ->
        %{
          success: false,
          message: "DNS resolution failed: #{inspect(reason)}"
        }
    end
  rescue
    e ->
      %{
        success: false,
        message: "Error: #{Exception.message(e)}"
      }
  end

  # Try to send a UDP packet and see if we get an ICMP unreachable
  # This is a best-effort test since SNMP uses UDP
  defp test_udp_reachability(host, ip_addr, port) do
    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, socket} ->
        # Send a minimal SNMP GET request packet
        # This is a simplified SNMPv1 GET for sysDescr.0 (.1.3.6.1.2.1.1.1.0)
        snmp_packet = build_snmp_get_request()

        :gen_udp.send(socket, ip_addr, port, snmp_packet)

        # Wait briefly for a response (300ms timeout)
        result =
          case :gen_udp.recv(socket, 0, 3_000) do
            {:ok, {_addr, _recv_port, _data}} ->
              %{
                success: true,
                message: "SNMP agent responded at #{host}:#{port}"
              }

            {:error, :timeout} ->
              # No response could mean firewall, wrong community, or host down
              # Report as potentially reachable since UDP is connectionless
              %{
                success: true,
                message: "Host #{host}:#{port} is reachable (no SNMP response - check community string)"
              }

            {:error, :econnrefused} ->
              %{
                success: false,
                message: "ICMP port unreachable - no SNMP agent on #{host}:#{port}"
              }

            {:error, reason} ->
              %{
                success: false,
                message: "UDP test failed: #{inspect(reason)}"
              }
          end

        :gen_udp.close(socket)
        result

      {:error, reason} ->
        %{
          success: false,
          message: "Failed to create test socket: #{inspect(reason)}"
        }
    end
  end

  # Build a minimal SNMPv1 GET request for sysDescr.0
  # This is used just to elicit a response from the SNMP agent
  defp build_snmp_get_request do
    # SNMPv1 GET request structure (ASN.1 BER encoded)
    # Request for .1.3.6.1.2.1.1.1.0 (sysDescr.0) with community "public"
    <<
      # SEQUENCE (total length 0x27 = 39 bytes)
      0x30,
      0x27,
      # INTEGER - version (0 = SNMPv1)
      0x02,
      0x01,
      0x00,
      # OCTET STRING - community "public"
      0x04,
      0x06,
      "public",
      # GetRequest-PDU (length 0x1A = 26 bytes)
      0xA0,
      0x1A,
      # INTEGER - request-id
      0x02,
      0x04,
      0x00,
      0x00,
      0x00,
      0x01,
      # INTEGER - error-status
      0x02,
      0x01,
      0x00,
      # INTEGER - error-index
      0x02,
      0x01,
      0x00,
      # SEQUENCE - variable-bindings (length 0x0C = 12 bytes)
      0x30,
      0x0C,
      # SEQUENCE - single binding (length 0x0A = 10 bytes)
      0x30,
      0x0A,
      # OID - .1.3.6.1.2.1.1.1.0 (sysDescr.0) - length 8
      0x06,
      0x08,
      0x2B,
      0x06,
      0x01,
      0x02,
      0x01,
      0x01,
      0x01,
      0x00,
      # NULL value
      0x05,
      0x00
    >>
  end

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> 1.0
    end
  end

  defp parse_float(value) when is_float(value), do: value
  defp parse_float(value) when is_integer(value), do: value / 1
  defp parse_float(_), do: 1.0

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path="/settings/snmp">
        <.settings_nav current_path="/settings/snmp" current_scope={@current_scope} />
        <.network_nav current_path="/settings/snmp" current_scope={@current_scope} />

        <div class="space-y-4">
          <!-- Content based on form state -->
          <%= if @show_form in [:new_profile, :edit_profile] do %>
            <.profile_form
              form={@form}
              show_form={@show_form}
              selected_profile={@selected_profile}
              target_device_count={@target_device_count}
              target_entity={@target_entity}
              builder_open={@builder_open}
              builder={@builder}
              builder_sync={@builder_sync}
              targets={@targets}
              selected_template_ids={@selected_template_ids}
              available_templates={@available_templates}
            />
          <% else %>
            <.profiles_panel
              profiles={@profiles}
              profile_target_counts={@profile_target_counts}
            />
          <% end %>
        </div>
        
    <!-- Target Modal -->
        <.target_modal
          :if={@show_target_modal}
          form={@target_form}
          editing_target={@editing_target}
          show_password={@show_password}
          target_oids={@target_oids}
          test_connection_result={@test_connection_result}
          test_connection_loading={@test_connection_loading}
        />
        
    <!-- Template Browser Modal -->
        <.template_browser_modal
          :if={@show_template_browser}
          search={@template_search}
          selected_vendor={@selected_vendor}
          custom_templates={@custom_templates}
        />
        
    <!-- Custom Template Modal -->
        <.custom_template_modal
          :if={@show_custom_template_modal}
          form={@custom_template_form}
          oids={@custom_template_oids}
          editing={@editing_custom_template}
        />
      </.settings_shell>
    </Layouts.app>
    """
  end

  # Profiles Panel
  attr :profiles, :list, required: true
  attr :profile_target_counts, :map, default: %{}

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
                  {profile.poll_interval}s
                </td>
                <td>
                  <.ui_badge
                    id={"snmp-profile-#{profile.id}-targets"}
                    variant="ghost"
                    size="xs"
                    title={target_count_title(Map.get(@profile_target_counts, profile.id))}
                  >
                    {format_target_count(Map.get(@profile_target_counts, profile.id))}
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
  attr :target_device_count, :any, default: nil
  attr :target_entity, :string, default: "devices"
  attr :builder_open, :boolean, default: false
  attr :builder, :map, default: %{}
  attr :builder_sync, :boolean, default: true
  attr :targets, :list, default: []
  attr :selected_template_ids, :list, default: []
  attr :available_templates, :list, default: []

  defp profile_form(assigns) do
    is_default = assigns.selected_profile && assigns.selected_profile.is_default
    config = Catalog.entity("interfaces")
    version = get_form_value(assigns.form, :version, "v2c")

    assigns =
      assigns
      |> assign(:is_default, is_default)
      |> assign(:config, config)
      |> assign(:version, version)

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
        
    <!-- SNMP Credentials Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            SNMP Credentials
          </h3>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
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

          <%= if @version in ["v1", "v2c"] do %>
            <div>
              <label class="label"><span class="label-text">Community String</span></label>
              <.input
                type="password"
                name="form[community]"
                value=""
                class="input input-bordered w-full"
                placeholder={
                  if @show_form == :edit_profile,
                    do: "Leave blank to keep existing",
                    else: "e.g., public"
                }
                autocomplete="off"
              />
              <label class="label">
                <span class="label-text-alt text-base-content/50">
                  Credentials are encrypted at rest.
                </span>
              </label>
            </div>
          <% else %>
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
                <.input
                  type="password"
                  name="form[auth_password]"
                  value=""
                  class="input input-bordered w-full"
                  placeholder={
                    if @show_form == :edit_profile,
                      do: "Leave blank to keep existing",
                      else: "Auth password"
                  }
                  autocomplete="off"
                />
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
                  type="password"
                  name="form[priv_password]"
                  value=""
                  class="input input-bordered w-full"
                  placeholder={
                    if @show_form == :edit_profile,
                      do: "Leave blank to keep existing",
                      else: "Privacy password"
                  }
                  autocomplete="off"
                />
              </div>
            </div>

            <p class="text-xs text-base-content/50">
              Leave password fields blank to keep existing values. Credentials are encrypted at rest.
            </p>
          <% end %>
        </div>
        
    <!-- Interface Targeting Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Interface Targeting
          </h3>

          <div class="space-y-4">
            <div :if={@is_default} class="bg-info/10 border border-info/30 rounded-lg p-4">
              <div class="flex items-start gap-3">
                <.icon name="hero-information-circle" class="size-5 text-info shrink-0 mt-0.5" />
                <div>
                  <p class="text-sm font-medium">Default Profile</p>
                  <p class="text-xs text-base-content/70 mt-1">
                    This profile acts as the fallback for any interfaces that don't match other profiles.
                    You can still set a targeting query here to scope the default and preview counts.
                  </p>
                </div>
              </div>
            </div>
            
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
                  SRQL filters to match interfaces. Examples: <code class="bg-base-200 px-1 rounded">type:ethernet</code>,
                  <code class="bg-base-200 px-1 rounded">device.hostname:%router%</code>
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
            
    <!-- Target Count Preview -->
            <div :if={@target_device_count != nil} class="flex items-center gap-2">
              <.icon name="hero-signal" class="size-4 text-base-content/60" />
              <span class="text-sm">
                <%= case @target_device_count do %>
                  <% {:ok, count} -> %>
                    <span class="font-semibold">{count}</span>
                    <span class="text-base-content/60">
                      device(s) match this {if @target_entity == "interfaces",
                        do: "interface",
                        else: "device"} query
                    </span>
                  <% _ -> %>
                    <span class="font-semibold">Unknown</span>
                    <span class="text-base-content/60">targets for this query</span>
                <% end %>
              </span>
              <.ui_badge variant="ghost" size="xs">
                {if @target_entity == "interfaces", do: "Interfaces", else: "Devices"}
              </.ui_badge>
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
        
    <!-- OID Templates Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            OID Templates
          </h3>
          <p class="text-sm text-base-content/60">
            Select OID templates to define what metrics are polled from devices matched by this profile.
          </p>
          
    <!-- Selected Templates -->
          <div :if={@selected_template_ids != []} class="flex flex-wrap gap-2">
            <%= for template_id <- @selected_template_ids do %>
              <% template = Enum.find(@available_templates, &(&1.id == template_id)) %>
              <div
                :if={template}
                class="inline-flex items-center gap-2 px-3 py-1.5 bg-primary/10 text-primary rounded-full text-sm"
              >
                <span>{template.name}</span>
                <button
                  type="button"
                  class="hover:bg-primary/20 rounded-full p-0.5"
                  phx-click="remove_template"
                  phx-value-id={template_id}
                  title="Remove template"
                >
                  <.icon name="hero-x-mark" class="size-3" />
                </button>
              </div>
            <% end %>
          </div>
          
    <!-- Template Dropdown -->
          <div class="dropdown dropdown-bottom w-full max-w-md">
            <div tabindex="0" role="button" class="btn btn-outline w-full justify-between">
              <span>
                <.icon name="hero-plus" class="size-4 mr-2" /> Add OID Template
              </span>
              <.icon name="hero-chevron-down" class="size-4" />
            </div>
            <ul
              tabindex="0"
              class="dropdown-content menu bg-base-100 rounded-box z-[1] w-full max-h-60 overflow-y-auto p-2 shadow border border-base-200"
            >
              <li :if={@available_templates == []}>
                <span class="text-base-content/50">No templates available</span>
              </li>
              <%= for template <- @available_templates do %>
                <% selected = template.id in @selected_template_ids %>
                <li>
                  <button
                    type="button"
                    class={"flex items-center justify-between #{if selected, do: "bg-primary/10"}"}
                    phx-click="toggle_template"
                    phx-value-id={template.id}
                  >
                    <div class="flex flex-col items-start">
                      <span class="font-medium">{template.name}</span>
                      <span class="text-xs text-base-content/60">
                        {template.vendor} · {template.oid_count} OID(s)
                      </span>
                    </div>
                    <.icon :if={selected} name="hero-check" class="size-4 text-primary" />
                  </button>
                </li>
              <% end %>
            </ul>
          </div>

          <p class="text-xs text-base-content/50">
            OID templates define which SNMP metrics (OIDs) to poll. Select one or more templates to monitor
            interface traffic, CPU/memory, environment sensors, or other vendor-specific metrics.
          </p>
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
      
    <!-- Legacy SNMP Targets Section (deprecated, only shown when existing targets present) -->
      <div
        :if={@show_form == :edit_profile && @targets != []}
        class="mt-6 pt-6 border-t border-base-200"
      >
        <div class="bg-warning/10 border border-warning/30 rounded-lg p-4 mb-4">
          <div class="flex items-start gap-3">
            <.icon name="hero-exclamation-triangle" class="size-5 text-warning shrink-0 mt-0.5" />
            <div>
              <p class="text-sm font-medium">Legacy Configuration</p>
              <p class="text-xs text-base-content/70 mt-1">
                Manual SNMP targets are deprecated. Targets are now automatically derived from devices
                matched by the target query. Existing targets will continue to work but cannot be edited.
                Configure SNMP credentials on individual devices in the Inventory section.
              </p>
            </div>
          </div>
        </div>

        <h3 class="text-sm font-semibold uppercase tracking-wide text-base-content/60 mb-4">
          Legacy Manual Targets ({length(@targets)})
        </h3>

        <div class="overflow-x-auto">
          <table class="table table-sm opacity-75">
            <thead>
              <tr class="text-xs uppercase tracking-wide text-base-content/60">
                <th>Name</th>
                <th>Host</th>
                <th>Port</th>
                <th>Version</th>
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
  attr :target_oids, :list, default: []
  attr :test_connection_result, :map, default: nil
  attr :test_connection_loading, :boolean, default: false

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
                    placeholder={
                      if @editing_target, do: "Enter new value to change", else: "e.g., public"
                    }
                    autocomplete="off"
                  />
                  <.ui_icon_button
                    type="button"
                    phx-click="toggle_password_visibility"
                    title={if @show_password, do: "Hide", else: "Show"}
                  >
                    <.icon
                      name={if @show_password, do: "hero-eye-slash", else: "hero-eye"}
                      class="size-4"
                    />
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
                      <.icon
                        name={if @show_password, do: "hero-eye-slash", else: "hero-eye"}
                        class="size-4"
                      />
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
          
    <!-- OIDs Section -->
          <div class="space-y-4">
            <div class="flex items-center justify-between">
              <h4 class="text-sm font-semibold text-base-content/70">OIDs to Monitor</h4>
              <div class="flex items-center gap-2">
                <.ui_button
                  type="button"
                  variant="ghost"
                  size="sm"
                  phx-click="open_template_browser"
                >
                  <.icon name="hero-document-duplicate" class="size-4" /> Use Template
                </.ui_button>
                <.ui_button
                  type="button"
                  variant="ghost"
                  size="sm"
                  phx-click="add_oid"
                >
                  <.icon name="hero-plus" class="size-4" /> Add OID
                </.ui_button>
              </div>
            </div>

            <div
              :if={@target_oids == []}
              class="text-center py-6 text-base-content/60 bg-base-200/30 rounded-lg"
            >
              <.icon name="hero-variable" class="size-8 mx-auto mb-2 opacity-50" />
              <p class="text-sm">No OIDs configured</p>
              <p class="text-xs mt-1">Add OIDs manually or select from a template</p>
            </div>

            <div :if={@target_oids != []} class="space-y-3">
              <%= for {oid, idx} <- Enum.with_index(@target_oids) do %>
                <div class="flex items-start gap-2 p-3 bg-base-200/30 rounded-lg">
                  <div class="flex-1 grid grid-cols-1 md:grid-cols-6 gap-2">
                    <div class="md:col-span-2">
                      <input
                        type="text"
                        value={oid["oid"]}
                        placeholder=".1.3.6.1.2.1.1.1.0"
                        class="input input-bordered input-sm w-full font-mono text-xs"
                        phx-blur="update_oid"
                        phx-value-index={idx}
                        phx-value-field="oid"
                        name={"oid_#{idx}_oid"}
                      />
                      <span class="text-[10px] text-base-content/50">OID</span>
                    </div>
                    <div class="md:col-span-2">
                      <input
                        type="text"
                        value={oid["name"]}
                        placeholder="sysDescr"
                        class="input input-bordered input-sm w-full text-xs"
                        phx-blur="update_oid"
                        phx-value-index={idx}
                        phx-value-field="name"
                        name={"oid_#{idx}_name"}
                      />
                      <span class="text-[10px] text-base-content/50">Name</span>
                    </div>
                    <div>
                      <select
                        class="select select-bordered select-sm w-full text-xs"
                        phx-change="update_oid"
                        phx-value-index={idx}
                        phx-value-field="data_type"
                        name={"oid_#{idx}_data_type"}
                      >
                        <option value="gauge" selected={oid["data_type"] == "gauge"}>Gauge</option>
                        <option value="counter" selected={oid["data_type"] == "counter"}>
                          Counter
                        </option>
                        <option value="string" selected={oid["data_type"] == "string"}>String</option>
                        <option value="timeticks" selected={oid["data_type"] == "timeticks"}>
                          Timeticks
                        </option>
                      </select>
                      <span class="text-[10px] text-base-content/50">Type</span>
                    </div>
                    <div class="flex items-center gap-2">
                      <label class="flex items-center gap-1 cursor-pointer">
                        <input
                          type="checkbox"
                          class="checkbox checkbox-sm"
                          checked={oid["delta"] == true or oid["delta"] == "true"}
                          phx-click="update_oid"
                          phx-value-index={idx}
                          phx-value-field="delta"
                          phx-value-delta={
                            to_string(!(oid["delta"] == true or oid["delta"] == "true"))
                          }
                        />
                        <span class="text-xs">Delta</span>
                      </label>
                    </div>
                  </div>
                  <.ui_icon_button
                    type="button"
                    size="sm"
                    phx-click="remove_oid"
                    phx-value-index={idx}
                    title="Remove OID"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </.ui_icon_button>
                </div>
              <% end %>
            </div>

            <p class="text-xs text-base-content/50">
              Configure which SNMP OIDs to poll from this target. Use templates for common device types.
            </p>
          </div>
          
    <!-- Test Connection -->
          <div class="space-y-3">
            <div class="flex items-center gap-3">
              <.ui_button
                type="button"
                variant="outline"
                size="sm"
                phx-click="test_connection"
                disabled={@test_connection_loading}
              >
                <%= if @test_connection_loading do %>
                  <span class="loading loading-spinner loading-xs mr-2"></span> Testing...
                <% else %>
                  <.icon name="hero-signal" class="size-4 mr-2" /> Test Connection
                <% end %>
              </.ui_button>
              <span class="text-xs text-base-content/50">
                Verify connectivity to the SNMP agent
              </span>
            </div>
            
    <!-- Test Result -->
            <%= if @test_connection_result do %>
              <div class={[
                "flex items-center gap-2 p-3 rounded-lg text-sm",
                @test_connection_result.success && "bg-success/10 text-success",
                !@test_connection_result.success && "bg-error/10 text-error"
              ]}>
                <%= if @test_connection_result.success do %>
                  <.icon name="hero-check-circle" class="size-5" />
                <% else %>
                  <.icon name="hero-x-circle" class="size-5" />
                <% end %>
                <span>{@test_connection_result.message}</span>
              </div>
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

  # Template Browser Modal
  attr :search, :string, default: ""
  attr :selected_vendor, :string, default: "standard"
  attr :custom_templates, :list, default: []

  defp template_browser_modal(assigns) do
    builtin_templates = BuiltinTemplates.all_templates()
    vendors = BuiltinTemplates.vendors()
    # Add "Custom" vendor tab
    vendors_with_custom = vendors ++ [%{id: "custom", name: "Custom"}]

    is_custom_tab = assigns.selected_vendor == "custom"

    # Filter templates based on selected vendor
    filtered_templates =
      if is_custom_tab do
        # Show custom templates
        assigns.custom_templates
        |> Enum.filter(fn t ->
          assigns.search == "" or
            String.contains?(String.downcase(t.name), String.downcase(assigns.search)) or
            String.contains?(
              String.downcase(t.description || ""),
              String.downcase(assigns.search)
            )
        end)
        |> Enum.map(fn t ->
          # Convert to a format compatible with the template display
          %{
            id: t.id,
            name: t.name,
            description: t.description,
            vendor: t.vendor,
            category: t.category,
            oids: t.oids || [],
            is_custom: true
          }
        end)
      else
        # Show builtin templates
        builtin_templates
        |> Enum.filter(fn t ->
          vendor_match = String.downcase(t.vendor) == String.downcase(assigns.selected_vendor)

          search_match =
            assigns.search == "" or
              String.contains?(String.downcase(t.name), String.downcase(assigns.search)) or
              String.contains?(
                String.downcase(t.description || ""),
                String.downcase(assigns.search)
              )

          vendor_match and search_match
        end)
        |> Enum.map(fn t -> Map.put(t, :is_custom, false) end)
      end

    assigns =
      assigns
      |> assign(:templates, filtered_templates)
      |> assign(:vendors, vendors_with_custom)
      |> assign(:is_custom_tab, is_custom_tab)

    ~H"""
    <dialog id="template_browser_modal" class="modal modal-open">
      <div class="modal-box max-w-3xl max-h-[80vh]">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            type="button"
            phx-click="close_template_browser"
          >
            x
          </button>
        </form>

        <h3 class="font-bold text-lg mb-4">OID Templates</h3>
        <p class="text-sm text-base-content/60 mb-4">
          Select a template to add pre-configured OIDs for common device types.
        </p>
        
    <!-- Search and Vendor Filter -->
        <div class="flex flex-col md:flex-row gap-4 mb-4">
          <div class="flex-1">
            <input
              type="text"
              value={@search}
              placeholder="Search templates..."
              class="input input-bordered w-full"
              phx-keyup="search_templates"
              phx-value-search=""
              name="search"
            />
          </div>
          <div :if={@is_custom_tab}>
            <.ui_button
              type="button"
              variant="primary"
              size="sm"
              phx-click="open_custom_template_modal"
            >
              <.icon name="hero-plus" class="size-4" /> New Template
            </.ui_button>
          </div>
        </div>
        
    <!-- Vendor Tabs -->
        <div class="tabs tabs-boxed mb-4">
          <%= for vendor <- @vendors do %>
            <button
              type="button"
              class={"tab #{if @selected_vendor == vendor.id, do: "tab-active", else: ""}"}
              phx-click="select_vendor"
              phx-value-vendor={vendor.id}
            >
              {vendor.name}
            </button>
          <% end %>
        </div>
        
    <!-- Templates List -->
        <div class="overflow-y-auto max-h-[40vh] space-y-2">
          <div :if={@templates == [] && !@is_custom_tab} class="text-center py-8 text-base-content/60">
            <.icon name="hero-document-magnifying-glass" class="size-10 mx-auto mb-2 opacity-50" />
            <p>No templates found</p>
          </div>

          <div :if={@templates == [] && @is_custom_tab} class="text-center py-8 text-base-content/60">
            <.icon name="hero-document-plus" class="size-10 mx-auto mb-2 opacity-50" />
            <p>No custom templates yet</p>
            <p class="text-xs mt-1">Create your own template or copy from a built-in template</p>
          </div>

          <%= for template <- @templates do %>
            <div class="flex items-center justify-between p-3 bg-base-200/30 rounded-lg hover:bg-base-200/50">
              <div class="flex-1">
                <div class="font-medium text-sm">{template.name}</div>
                <p :if={template.description} class="text-xs text-base-content/60 mt-0.5">
                  {template.description}
                </p>
                <div class="flex items-center gap-2 mt-1">
                  <.ui_badge variant="ghost" size="xs">
                    {length(template.oids)} OID(s)
                  </.ui_badge>
                  <.ui_badge :if={template.category} variant="info" size="xs">
                    {template.category}
                  </.ui_badge>
                </div>
              </div>
              <div class="flex items-center gap-2">
                <%= if template.is_custom do %>
                  <!-- Custom template actions: Edit, Delete, Add -->
                  <.ui_button
                    type="button"
                    variant="ghost"
                    size="sm"
                    phx-click="edit_custom_template"
                    phx-value-id={template.id}
                    title="Edit template"
                  >
                    <.icon name="hero-pencil" class="size-4" />
                  </.ui_button>
                  <.ui_button
                    type="button"
                    variant="ghost"
                    size="sm"
                    phx-click="delete_custom_template"
                    phx-value-id={template.id}
                    title="Delete template"
                    data-confirm="Are you sure you want to delete this template?"
                  >
                    <.icon name="hero-trash" class="size-4 text-error" />
                  </.ui_button>
                  <.ui_button
                    type="button"
                    variant="primary"
                    size="sm"
                    phx-click="add_custom_template_oids"
                    phx-value-id={template.id}
                  >
                    <.icon name="hero-plus" class="size-4" /> Add
                  </.ui_button>
                <% else %>
                  <!-- Built-in template actions: Copy, Add -->
                  <.ui_button
                    type="button"
                    variant="ghost"
                    size="sm"
                    phx-click="copy_template_to_custom"
                    phx-value-template_id={template.id}
                    title="Create editable copy"
                  >
                    <.icon name="hero-document-duplicate" class="size-4" />
                  </.ui_button>
                  <.ui_button
                    type="button"
                    variant="primary"
                    size="sm"
                    phx-click="add_template_oids"
                    phx-value-template_id={template.id}
                  >
                    <.icon name="hero-plus" class="size-4" /> Add
                  </.ui_button>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
        
    <!-- Modal Actions -->
        <div class="modal-action">
          <.ui_button type="button" variant="ghost" phx-click="close_template_browser">
            Close
          </.ui_button>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="close_template_browser">close</button>
      </form>
    </dialog>
    """
  end

  # Custom Template Modal
  attr :form, :any, required: true
  attr :oids, :list, default: []
  attr :editing, :any, default: nil

  defp custom_template_modal(assigns) do
    categories = [
      {"interface", "Interface"},
      {"cpu-memory", "CPU/Memory"},
      {"environment", "Environment"},
      {"bgp", "BGP"},
      {"system", "System"},
      {"other", "Other"}
    ]

    data_types = [
      {"gauge", "Gauge"},
      {"counter", "Counter"},
      {"string", "String"},
      {"integer", "Integer"},
      {"timeticks", "TimeTicks"}
    ]

    assigns =
      assigns
      |> assign(:categories, categories)
      |> assign(:data_types, data_types)

    ~H"""
    <dialog id="custom_template_modal" class="modal modal-open">
      <div class="modal-box max-w-2xl max-h-[85vh]">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            type="button"
            phx-click="close_custom_template_modal"
          >
            x
          </button>
        </form>

        <h3 class="font-bold text-lg mb-4">
          {if @editing, do: "Edit Custom Template", else: "New Custom Template"}
        </h3>

        <.form
          for={@form}
          phx-change="validate_custom_template"
          phx-submit="save_custom_template"
          class="space-y-4"
        >
          <!-- Template Name -->
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Template Name</span>
            </label>
            <.input
              type="text"
              field={@form[:name]}
              class="input input-bordered w-full"
              placeholder="e.g., My Router Monitoring"
            />
          </div>
          
    <!-- Description -->
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Description</span>
            </label>
            <.input
              type="textarea"
              field={@form[:description]}
              class="textarea textarea-bordered w-full"
              rows="2"
              placeholder="Describe what this template monitors..."
            />
          </div>
          
    <!-- Category -->
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Category</span>
            </label>
            <select name={@form[:category].name} class="select select-bordered w-full">
              <option value="">Select a category...</option>
              <%= for {value, label} <- @categories do %>
                <option value={value} selected={@form[:category].value == value}>{label}</option>
              <% end %>
            </select>
          </div>
          
    <!-- OIDs Section -->
          <div class="form-control">
            <div class="flex items-center justify-between mb-2">
              <label class="label">
                <span class="label-text font-medium">OID Definitions</span>
              </label>
              <.ui_button
                type="button"
                variant="ghost"
                size="sm"
                phx-click="add_template_oid"
              >
                <.icon name="hero-plus" class="size-4" /> Add OID
              </.ui_button>
            </div>

            <div
              :if={@oids == []}
              class="text-center py-6 text-base-content/60 bg-base-200/30 rounded-lg"
            >
              <.icon name="hero-variable" class="size-8 mx-auto mb-2 opacity-50" />
              <p class="text-sm">No OIDs defined</p>
              <p class="text-xs mt-1">Add OIDs to include in this template</p>
            </div>

            <div :if={@oids != []} class="space-y-3 max-h-[30vh] overflow-y-auto">
              <%= for {oid, idx} <- Enum.with_index(@oids) do %>
                <div class="flex items-start gap-2 p-3 bg-base-200/30 rounded-lg">
                  <div class="flex-1 grid grid-cols-2 gap-2">
                    <!-- OID -->
                    <div>
                      <label class="label py-0">
                        <span class="label-text text-xs">OID</span>
                      </label>
                      <input
                        type="text"
                        value={oid["oid"]}
                        placeholder=".1.3.6.1.2.1..."
                        class="input input-bordered input-sm w-full font-mono text-xs"
                        phx-blur="update_template_oid"
                        phx-value-index={idx}
                        phx-value-field="oid"
                        name="oid"
                      />
                    </div>
                    
    <!-- Name -->
                    <div>
                      <label class="label py-0">
                        <span class="label-text text-xs">Name</span>
                      </label>
                      <input
                        type="text"
                        value={oid["name"]}
                        placeholder="e.g., ifInOctets"
                        class="input input-bordered input-sm w-full text-xs"
                        phx-blur="update_template_oid"
                        phx-value-index={idx}
                        phx-value-field="name"
                        name="name"
                      />
                    </div>
                    
    <!-- Data Type -->
                    <div>
                      <label class="label py-0">
                        <span class="label-text text-xs">Data Type</span>
                      </label>
                      <select
                        class="select select-bordered select-sm w-full text-xs"
                        phx-change="update_template_oid"
                        phx-value-index={idx}
                        phx-value-field="data_type"
                        name="data_type"
                      >
                        <%= for {value, label} <- @data_types do %>
                          <option value={value} selected={oid["data_type"] == value}>{label}</option>
                        <% end %>
                      </select>
                    </div>
                    
    <!-- Scale -->
                    <div>
                      <label class="label py-0">
                        <span class="label-text text-xs">Scale</span>
                      </label>
                      <input
                        type="text"
                        value={oid["scale"]}
                        placeholder="1.0"
                        class="input input-bordered input-sm w-full text-xs"
                        phx-blur="update_template_oid"
                        phx-value-index={idx}
                        phx-value-field="scale"
                        name="scale"
                      />
                    </div>
                    
    <!-- Delta checkbox -->
                    <div class="col-span-2 flex items-center gap-2 mt-1">
                      <input
                        type="checkbox"
                        checked={oid["delta"]}
                        class="checkbox checkbox-sm"
                        phx-click="update_template_oid"
                        phx-value-index={idx}
                        phx-value-field="delta"
                        phx-value-delta={if oid["delta"], do: "false", else: "true"}
                        name="delta"
                      />
                      <span class="text-xs text-base-content/70">
                        Calculate delta (rate of change)
                      </span>
                    </div>
                  </div>
                  
    <!-- Remove button -->
                  <.ui_icon_button
                    type="button"
                    variant="ghost"
                    size="sm"
                    phx-click="remove_template_oid"
                    phx-value-index={idx}
                    title="Remove OID"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </.ui_icon_button>
                </div>
              <% end %>
            </div>
          </div>
          
    <!-- Modal Actions -->
          <div class="modal-action">
            <.ui_button type="button" variant="ghost" phx-click="close_custom_template_modal">
              Cancel
            </.ui_button>
            <.ui_button type="submit" variant="primary">
              {if @editing, do: "Update Template", else: "Create Template"}
            </.ui_button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="close_custom_template_modal">close</button>
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

  defp assign_profiles_with_counts(socket, scope) do
    {profiles, profile_target_counts} = load_profiles_with_counts(scope)

    socket
    |> assign(:profiles, profiles)
    |> assign(:profile_target_counts, profile_target_counts)
  end

  defp assign_target_preview(socket, target_query) do
    scope = socket.assigns.current_scope

    is_default =
      case socket.assigns.selected_profile do
        %{is_default: true} -> true
        _ -> false
      end

    normalized_query = normalize_target_query(target_query, is_default)

    if is_nil(normalized_query) do
      socket
      |> assign(:target_device_count, nil)
      |> assign(:target_entity, "devices")
    else
      target_entity = extract_srql_entity(normalized_query)
      device_count = count_target_devices(scope, normalized_query)

      socket
      |> assign(:target_device_count, device_count)
      |> assign(:target_entity, target_entity)
    end
  end

  defp normalize_target_query(target_query, is_default) do
    cond do
      target_query in [nil, ""] and is_default ->
        "in:devices"

      target_query in [nil, ""] ->
        nil

      true ->
        normalize_target_query(target_query)
    end
  end

  defp normalize_target_query(query) when is_binary(query) do
    query = String.trim(query)

    cond do
      query == "" ->
        "in:devices"

      String.starts_with?(query, "in:") ->
        query

      true ->
        "in:devices " <> query
    end
  end

  defp normalize_target_query(_), do: nil

  defp format_target_count({:ok, count}) do
    label = if count == 1, do: "target", else: "targets"
    "#{count} #{label}"
  end

  defp format_target_count(_), do: "Unknown"

  defp target_count_title({:ok, _count}), do: nil
  defp target_count_title(_), do: "Target count unavailable"

  # Helper Functions
  defp load_profiles_with_counts(scope) do
    profiles = load_profiles(scope)
    counts = load_profile_target_counts(scope, profiles)
    {profiles, counts}
  end

  defp load_profiles(scope) do
    case Ash.read(SNMPProfile, scope: scope) do
      {:ok, profiles} ->
        # Sort by priority (highest first), then by name
        Enum.sort_by(profiles, fn p -> {-p.priority, p.name} end)

      {:error, _} ->
        []
    end
  end

  defp load_profile_target_counts(_scope, []), do: %{}

  defp load_profile_target_counts(scope, profiles) do
    Enum.reduce(profiles, %{}, fn profile, acc ->
      target_query = resolve_target_query(profile.target_query, profile.is_default)
      normalized_query = normalize_target_query(target_query, profile.is_default)
      count = count_target_devices(scope, normalized_query)

      Map.put(acc, profile.id, count)
    end)
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

  defp load_target_oids(scope, target_id) do
    query =
      SNMPOIDConfig
      |> Ash.Query.filter(snmp_target_id == ^target_id)
      |> Ash.Query.sort(:name)

    case Ash.read(query, scope: scope) do
      {:ok, oids} ->
        # Convert to map format for UI
        Enum.map(oids, fn oid ->
          %{
            "id" => oid.id,
            "oid" => oid.oid,
            "name" => oid.name,
            "data_type" => to_string(oid.data_type),
            "scale" => to_string(oid.scale),
            "delta" => oid.delta
          }
        end)

      {:error, _} ->
        []
    end
  end

  defp load_custom_templates(scope) do
    case Ash.read(SNMPOIDTemplate, action: :list_custom, scope: scope) do
      {:ok, templates} -> templates
      {:error, _} -> []
    end
  end

  defp load_all_templates(scope) do
    # Load builtin templates
    builtin =
      Enum.map(BuiltinTemplates.all_templates(), fn t ->
        %{
          id: t.id,
          name: t.name,
          description: t.description,
          vendor: t.vendor,
          category: t.category,
          oid_count: length(t.oids || []),
          is_builtin: true
        }
      end)

    # Load custom templates from database
    custom =
      case Ash.read(SNMPOIDTemplate, action: :list_custom, scope: scope) do
        {:ok, templates} ->
          Enum.map(templates, fn t ->
            %{
              id: t.id,
              name: t.name,
              description: t.description,
              vendor: t.vendor,
              category: t.category,
              oid_count: length(t.oids || []),
              is_builtin: false
            }
          end)

        {:error, _} ->
          []
      end

    builtin ++ custom
  end

  # Resolve target query for a profile, using defaults for default profiles
  defp resolve_target_query(nil, true), do: "in:devices"
  defp resolve_target_query("", true), do: "in:devices"
  defp resolve_target_query(nil, _is_default), do: nil
  defp resolve_target_query("", _is_default), do: ""
  defp resolve_target_query(query, _is_default), do: query

  defp count_target_devices(_scope, nil), do: :unknown
  defp count_target_devices(_scope, ""), do: :unknown

  defp count_target_devices(scope, target_query) when is_binary(target_query) do
    # Parse the SRQL query and count matching targets based on entity type
    entity = extract_srql_entity(target_query)

    with {:ok, ast_json} <- ServiceRadarSRQL.Native.parse_ast(target_query),
         {:ok, ast} <- Jason.decode(ast_json) do
      count_entity_from_ast(scope, entity, ast)
    else
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  # Helper to count entities from parsed AST (extracted to reduce nesting depth)
  defp count_entity_from_ast(scope, entity, ast) do
    case entity do
      "devices" -> count_devices_from_ast(scope, ast)
      "interfaces" -> count_interfaces_from_ast(scope, ast)
      _ -> count_devices_from_ast(scope, ast)
    end
  end

  defp extract_srql_entity(query) when is_binary(query) do
    query = String.trim(query)

    case Regex.run(~r/^in:(\S+)/, query) do
      [_, entity] -> String.downcase(entity)
      _ -> "devices"
    end
  end

  defp extract_srql_entity(_), do: "devices"

  defp count_devices_from_ast(scope, ast) do
    filters = extract_srql_filters(ast)

    query =
      Device
      |> Ash.Query.for_read(:read, %{})
      |> apply_device_filters(filters)

    case query do
      {:error, :unsupported_filter} ->
        :unknown

      query ->
        case Ash.count(query, scope: scope) do
          {:ok, count} -> {:ok, count}
          _ -> :unknown
        end
    end
  rescue
    _ -> :unknown
  end

  defp count_interfaces_from_ast(scope, ast) do
    filters = extract_srql_filters(ast)

    query =
      Interface
      |> Ash.Query.for_read(:read, %{})
      |> apply_srql_filters(filters)
      # Add distinct on device_id to avoid counting historical snapshots
      |> Ash.Query.distinct(:device_id)

    case Ash.count(query, scope: scope) do
      {:ok, count} -> {:ok, count}
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  defp apply_device_filters(query, filters) do
    Enum.reduce_while(filters, query, fn filter, q ->
      case apply_device_filter(q, filter) do
        {:ok, updated} -> {:cont, updated}
        {:error, :unsupported_filter} -> {:halt, {:error, :unsupported_filter}}
      end
    end)
  end

  defp apply_device_filter(query, %{field: field, op: op, value: value}) when is_binary(field) do
    case map_device_field(field) do
      nil -> {:error, :unsupported_filter}
      mapped_field -> {:ok, apply_field_filter(query, mapped_field, op, value)}
    end
  rescue
    _ -> {:error, :unsupported_filter}
  end

  defp apply_device_filter(_query, _), do: {:error, :unsupported_filter}

  @device_srql_field_mapping %{
    "uid" => :uid,
    "device_id" => :uid,
    "hostname" => :hostname,
    "name" => :name,
    "ip" => :ip,
    "gateway_id" => :gateway_id,
    "agent_id" => :agent_id,
    "vendor_name" => :vendor_name,
    "model" => :model,
    "type" => :type,
    "type_id" => :type_id
  }

  defp map_device_field(field), do: Map.get(@device_srql_field_mapping, field)

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
    case map_srql_field(field) do
      nil -> query
      mapped_field -> apply_field_filter(query, mapped_field, op, value)
    end
  rescue
    _ -> query
  end

  defp apply_srql_filter(query, _), do: query

  # Map SRQL interface fields to Ash attributes
  @srql_field_mapping %{
    "if_name" => :if_name,
    "name" => :if_name,
    "if_descr" => :if_descr,
    "description" => :if_descr,
    "if_alias" => :if_alias,
    "alias" => :if_alias,
    "device_id" => :device_id,
    "device_ip" => :device_ip,
    "ip" => :device_ip,
    "gateway_id" => :gateway_id,
    "agent_id" => :agent_id,
    "if_oper_status" => :if_oper_status,
    "oper_status" => :if_oper_status,
    "if_admin_status" => :if_admin_status,
    "admin_status" => :if_admin_status,
    "if_speed" => :if_speed,
    "speed" => :if_speed,
    "if_phys_address" => :if_phys_address,
    "mac" => :if_phys_address
  }

  defp map_srql_field(field), do: Map.get(@srql_field_mapping, field)

  # Apply filter based on SRQL operator
  # Supports both UI operators (equals, contains) and legacy operators (eq, like)
  defp apply_field_filter(query, field, op, value) when op in ["eq", "equals"] do
    Ash.Query.filter_input(query, %{field => %{eq: value}})
  end

  defp apply_field_filter(query, field, op, value) when op in ["not_eq", "not_equals"] do
    Ash.Query.filter_input(query, %{field => %{not_eq: value}})
  end

  defp apply_field_filter(query, field, "contains", value) do
    Ash.Query.filter_input(query, %{field => %{contains: value}})
  end

  defp apply_field_filter(query, field, "like", value) do
    # Legacy SRQL "like" values contain % wildcards, strip them for Ash contains
    stripped = value |> String.trim_leading("%") |> String.trim_trailing("%")
    Ash.Query.filter_input(query, %{field => %{contains: stripped}})
  end

  defp apply_field_filter(query, _field, op, _value) when op in ["not_like", "not_contains"] do
    # Skip negative contains - count will be an approximation
    # Ash doesn't have a direct not_contains filter
    query
  end

  defp apply_field_filter(query, field, _op, value) do
    # Default to equality for unknown operators
    Ash.Query.filter_input(query, %{field => %{eq: value}})
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
        value = value |> String.trim() |> String.replace("\\ ", " ")

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

  defp maybe_set_target_query(form, nil), do: form
  defp maybe_set_target_query(form, ""), do: form

  defp maybe_set_target_query(form, target_query) do
    Form.validate(form, %{"target_query" => target_query})
  end

  defp normalize_filter_op(op) when op in ["contains", "not_contains", "equals", "not_equals"], do: op

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

      ash_form = Form.validate(socket.assigns.ash_form, %{"target_query" => query})

      socket
      |> assign(:ash_form, ash_form)
      |> assign(:form, to_form(ash_form))
      |> assign_target_preview(query)
    else
      socket
    end
  end
end
