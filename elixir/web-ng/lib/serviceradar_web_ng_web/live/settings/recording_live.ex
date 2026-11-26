defmodule ServiceRadarWebNGWeb.Settings.RecordingLive do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Camera.NVRStorageSettings
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RetentionCalculator
  alias ServiceRadar.Camera.VantagePubSub
  alias ServiceRadarWebNG.CameraRecordingRuntime
  alias ServiceRadarWebNG.CameraRecordingSettings
  alias ServiceRadarWebNG.CameraVantageWorkers
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.RecordingLive.Components
  alias ServiceRadarWebNGWeb.Settings.Shell

  @path "/settings/recording"
  @supported_tabs ~w(recorders archive cameras policy retention health)
  @recording_permissions [
    "settings.recording.view",
    "settings.recording.manage",
    "settings.recording.operate"
  ]

  @doc "In-page tab query parameter values handled by this LiveView."
  @spec supported_tabs() :: [String.t()]
  def supported_tabs, do: @supported_tabs

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:current_scope]

    if scope != nil and RBAC.can_any?(scope, @recording_permissions) do
      default_settings = RecordingArchiveSettings.default_settings()
      default_usage = CameraRecordingSettings.default_usage_summary(default_settings)
      default_projection = RetentionCalculator.project_settings(default_settings, %{camera_count: 0})

      socket =
        socket
        |> assign(:page_title, "Recording & Storage")
        |> assign(:current_path, @path)
        |> assign(:active_tab, "recorders")
        |> assign(:can_manage?, RBAC.can?(scope, "settings.recording.manage"))
        |> assign(:can_operate?, RBAC.can?(scope, "settings.recording.operate"))
        |> assign(:can_hold?, RBAC.can?(scope, "devices.cameras.recordings.hold"))
        |> assign(:can_manage_credentials?, RBAC.can?(scope, "settings.credentials.manage"))
        |> assign(:runtime, initial_runtime())
        |> assign(:bindings, [])
        |> assign(:credentials, [])
        |> assign(:settings_record, nil)
        |> assign(:settings_struct, default_settings)
        |> assign(:entitlement, CameraRecordingSettings.default_entitlement_view())
        |> assign(:settings_form, CameraRecordingSettings.default_settings_form())
        |> assign(:retention_form, CameraRecordingSettings.default_retention_form())
        |> assign(:simulator_form, CameraRecordingSettings.default_simulator_form())
        |> assign(:retention_errors, %{})
        |> assign(:usage_summary, default_usage)
        |> assign(:retention_projection, default_projection)
        |> assign(:destination_form, CameraRecordingSettings.default_destination_form())
        |> assign(:destination_errors, %{})
        |> assign(:storage_mode, :local_only)
        |> assign(:active_binding_id, nil)
        |> assign(:active_binding_managed_by_cloud?, false)
        |> assign(:writer_managed_by_cloud?, false)
        |> assign(:reader_managed_by_cloud?, false)
        |> assign(:retention_managed_by_cloud?, false)
        |> assign(:selected_writer_label, "None selected")
        |> assign(:selected_reader_label, "Use writer credential (reader role)")
        |> assign(:selected_retention_label, "None selected (object retention not enforced)")
        |> assign(:object_retention_enforced?, false)
        |> assign(:credential_issue, nil)
        |> assign(:sources, [])
        |> assign(:profiles, [])
        |> assign(:sources_forbidden?, false)
        |> assign(:selected_camera_id, nil)
        |> assign(:selected_profile_id, nil)
        |> assign(:blocks_loaded?, false)
        |> assign(:blocks_stream_count, 0)
        |> assign(:blocks_empty?, true)
        |> assign(:blocks_filtered_more?, false)
        |> assign(:blocks_next_cursor, nil)
        |> assign(:policies, [])
        |> assign(:recording_now, MapSet.new())
        |> assign(:policy_profiles, [])
        |> assign(:policy_form, CameraRecordingSettings.default_policy_form(:local_only))
        |> assign(:policy_editing_revision, nil)
        |> assign(:policy_errors, %{})
        |> assign(:policy_what_if, CameraRecordingSettings.default_policy_what_if(default_settings))
        |> assign(:storage_settings_rows, [])
        |> assign(:storage_rows, [])
        |> assign(:storage_settings_form, CameraRecordingSettings.default_storage_settings_form())
        |> assign(:storage_settings_errors, %{})
        |> assign(:health_summary, CameraRecordingSettings.default_health_summary(default_settings))
        |> assign(:vantage_worker_summary, CameraVantageWorkers.default_summary())
        |> assign(:vantage_worker_subscribed?, false)
        |> stream(:recording_blocks, [], reset: true)

      if connected?(socket) do
        {:ok, load_connected_data(socket)}
      else
        {:ok, socket}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to view camera recording settings")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = normalize_tab(Map.get(params, "tab"))

    socket =
      socket
      |> assign(:active_tab, tab)
      |> maybe_apply_camera_param(Map.get(params, "camera_source_id"))

    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_status", _params, socket) do
    case authorize_any_recording_permission(socket) do
      {:ok, scope} ->
        socket =
          socket
          |> refresh_scope_flags(scope)
          |> load_connected_data()

        {:noreply, socket}

      {:error, denied_socket} ->
        {:noreply, denied_socket}
    end
  end

  def handle_event("select_camera_context", params, socket) do
    case authorize_any_recording_permission(socket) do
      {:ok, scope} ->
        camera_id = blank_to_nil(Map.get(params, "camera_source_id"))

        profile_id =
          if camera_id == socket.assigns.selected_camera_id do
            blank_to_nil(Map.get(params, "stream_profile_id"))
          end

        socket =
          socket
          |> refresh_scope_flags(scope)
          |> select_camera_and_load_blocks(camera_id, profile_id)

        {:noreply, socket}

      {:error, denied_socket} ->
        {:noreply, denied_socket}
    end
  end

  def handle_event("next_blocks_page", _params, socket) do
    case authorize_any_recording_permission(socket) do
      {:ok, scope} ->
        cursor = socket.assigns.blocks_next_cursor
        camera_id = socket.assigns.selected_camera_id
        profile_id = socket.assigns.selected_profile_id
        dependencies = deps(socket)

        if cursor != nil and camera_id != nil do
          {:ok, page} =
            dependencies.list_camera_blocks_page.(scope, camera_id,
              cursor: cursor,
              stream_profile_id: profile_id
            )

          new_count = socket.assigns.blocks_stream_count + length(page.rows)

          {:noreply,
           socket
           |> refresh_scope_flags(scope)
           |> assign(:blocks_stream_count, new_count)
           |> assign(:blocks_next_cursor, page.next_cursor)
           |> assign(:blocks_empty?, new_count == 0 and is_nil(page.next_cursor))
           |> assign(:blocks_filtered_more?, new_count == 0 and not is_nil(page.next_cursor))
           |> stream(:recording_blocks, page.rows)}
        else
          {:noreply, socket}
        end

      {:error, denied_socket} ->
        {:noreply, denied_socket}
    end
  end

  def handle_event("validate_destination", %{"destination" => dest_params}, socket) do
    dependencies = deps(socket)

    case dependencies.authorize_current.(
           socket.assigns.current_scope,
           "settings.recording.manage"
         ) do
      {:ok, scope} ->
        normalized = CameraRecordingSettings.normalize_destination_params(dest_params)

        {:noreply,
         socket
         |> refresh_scope_flags(scope)
         |> assign(:destination_form, normalized)
         |> assign(:destination_errors, %{})}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Not authorized to manage archive destinations")}
    end
  end

  def handle_event("register_destination", %{"destination" => dest_params}, socket) do
    dependencies = deps(socket)

    case dependencies.authorize_current.(
           socket.assigns.current_scope,
           "settings.recording.manage"
         ) do
      {:ok, scope} ->
        normalized = CameraRecordingSettings.normalize_destination_params(dest_params)

        case dependencies.register_operator_destination.(scope, normalized) do
          {:ok, binding} ->
            socket =
              socket
              |> refresh_scope_flags(scope)
              |> assign(:destination_form, CameraRecordingSettings.default_destination_form())
              |> assign(:destination_errors, %{})
              |> load_archive_data()
              |> put_flash(
                :info,
                "Registered #{binding.provisioning_ref} generation #{binding.generation}"
              )

            {:noreply, socket}

          {:error, field_errors} ->
            {:noreply,
             socket
             |> refresh_scope_flags(scope)
             |> assign(:destination_form, normalized)
             |> assign(:destination_errors, field_errors)}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Not authorized to manage archive destinations")}
    end
  end

  def handle_event("validate_archive_settings", %{"settings" => settings_params}, socket) do
    dependencies = deps(socket)

    case dependencies.authorize_current.(
           socket.assigns.current_scope,
           "settings.recording.manage"
         ) do
      {:ok, scope} ->
        can_manage_creds? =
          match?(
            {:ok, _},
            dependencies.authorize_current.(scope, "settings.credentials.manage")
          )

        next_form =
          CameraRecordingSettings.normalize_archive_settings_form(
            settings_params,
            socket.assigns.settings_form,
            can_manage_creds?
          )

        {:noreply,
         socket
         |> refresh_scope_flags(scope)
         |> assign(:can_manage_credentials?, can_manage_creds?)
         |> assign(:settings_form, next_form)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Not authorized to manage archive settings")}
    end
  end

  def handle_event("save_archive_settings", %{"settings" => settings_params}, socket) do
    dependencies = deps(socket)

    case dependencies.authorize_current.(
           socket.assigns.current_scope,
           "settings.recording.manage"
         ) do
      {:ok, scope} ->
        can_manage_creds? =
          match?(
            {:ok, _},
            dependencies.authorize_current.(scope, "settings.credentials.manage")
          )

        case dependencies.save_archive_settings.(scope, settings_params, can_manage_creds?) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> refresh_scope_flags(scope)
             |> assign(:can_manage_credentials?, can_manage_creds?)
             |> load_archive_data()
             |> load_policies_data()
             |> load_storage_and_health_data()
             |> put_flash(:info, "Archive settings saved")}

          {:error, message} ->
            {:noreply,
             socket
             |> refresh_scope_flags(scope)
             |> assign(:can_manage_credentials?, can_manage_creds?)
             |> put_flash(:error, message)}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Not authorized to manage archive settings")}
    end
  end

  def handle_event("preview_retention_settings", params, socket) do
    dependencies = deps(socket)

    case dependencies.authorize_current.(
           socket.assigns.current_scope,
           "settings.recording.manage"
         ) do
      {:ok, scope} ->
        retention_params = Map.get(params, "retention", %{})
        simulator_params = Map.get(params, "simulator", %{})

        preview =
          CameraRecordingSettings.preview_retention_settings(
            retention_params,
            simulator_params,
            prev_form: socket.assigns.retention_form,
            prev_simulator: socket.assigns.simulator_form,
            usage_summary: socket.assigns.usage_summary,
            existing: socket.assigns.settings_record,
            storage_mode: socket.assigns.storage_mode,
            entitlement: socket.assigns.entitlement,
            scope: scope
          )

        {:noreply,
         socket
         |> refresh_scope_flags(scope)
         |> assign(:retention_form, preview.retention_form)
         |> assign(:simulator_form, preview.simulator_form)
         |> assign(:retention_errors, preview.errors)
         |> assign(:retention_projection, preview.projection)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Not authorized to manage retention settings")}
    end
  end

  def handle_event("save_retention_settings", params, socket) do
    dependencies = deps(socket)

    case dependencies.authorize_current.(
           socket.assigns.current_scope,
           "settings.recording.manage"
         ) do
      {:ok, scope} ->
        retention_params = Map.get(params, "retention", %{})
        simulator_params = Map.get(params, "simulator", %{})

        case dependencies.save_retention_settings.(scope, retention_params) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> refresh_scope_flags(scope)
             |> assign(:retention_errors, %{})
             |> load_archive_data()
             |> load_policies_data()
             |> load_storage_and_health_data()
             |> put_flash(:info, "Retention settings saved")}

          {:error, field_errors} ->
            preview =
              CameraRecordingSettings.preview_retention_settings(
                retention_params,
                simulator_params,
                prev_form: socket.assigns.retention_form,
                prev_simulator: socket.assigns.simulator_form,
                usage_summary: socket.assigns.usage_summary,
                existing: socket.assigns.settings_record,
                storage_mode: socket.assigns.storage_mode,
                scope: scope
              )

            merged_errors = Map.merge(preview.errors, field_errors)

            {:noreply,
             socket
             |> refresh_scope_flags(scope)
             |> assign(:retention_form, preview.retention_form)
             |> assign(:simulator_form, preview.simulator_form)
             |> assign(:retention_errors, merged_errors)
             |> assign(:retention_projection, preview.projection)
             |> put_flash(:error, first_error_message(merged_errors, "Invalid retention settings"))}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Not authorized to manage retention settings")}
    end
  end

  def handle_event("edit_policy", params, socket) do
    dependencies = deps(socket)

    case dependencies.authorize_current.(
           socket.assigns.current_scope,
           "settings.recording.manage"
         ) do
      {:ok, scope} ->
        policy_id = to_string(Map.get(params, "id", ""))

        case Enum.find(socket.assigns.policies, &(to_string(Map.get(&1, :id)) == policy_id)) do
          nil ->
            {:noreply, refresh_scope_flags(socket, scope)}

          policy ->
            cam_id = to_string(Map.get(policy, :camera_source_id) || "")
            policy_profiles = dependencies.list_relay_profiles.(scope, cam_id)
            form = CameraRecordingSettings.policy_form_from_policy(policy, socket.assigns.storage_mode)

            what_if =
              dependencies.what_if_policy_preview.(
                scope,
                form,
                policy_preview_opts(socket, policy_profiles)
              )

            {:noreply,
             socket
             |> refresh_scope_flags(scope)
             |> assign(:policy_profiles, policy_profiles)
             |> assign(:policy_form, form)
             |> assign(:policy_editing_revision, Map.get(policy, :policy_revision))
             |> assign(:policy_errors, %{})
             |> assign(:policy_what_if, what_if)}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Not authorized to manage recording policies")}
    end
  end

  def handle_event("reset_policy_form", _params, socket) do
    dependencies = deps(socket)

    case dependencies.authorize_current.(
           socket.assigns.current_scope,
           "settings.recording.manage"
         ) do
      {:ok, scope} ->
        form = CameraRecordingSettings.default_policy_form(socket.assigns.storage_mode)

        what_if =
          dependencies.what_if_policy_preview.(scope, form, policy_preview_opts(socket, []))

        {:noreply,
         socket
         |> refresh_scope_flags(scope)
         |> assign(:policy_profiles, [])
         |> assign(:policy_form, form)
         |> assign(:policy_editing_revision, nil)
         |> assign(:policy_errors, %{})
         |> assign(:policy_what_if, what_if)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Not authorized to manage recording policies")}
    end
  end

  def handle_event("preview_policy", params, socket) do
    dependencies = deps(socket)

    case dependencies.authorize_current.(
           socket.assigns.current_scope,
           "settings.recording.manage"
         ) do
      {:ok, scope} ->
        policy_params = Map.get(params, "policy", params)
        prev_cam = socket.assigns.policy_form["camera_source_id"] || ""
        next_cam = policy_params |> Map.get("camera_source_id", prev_cam) |> to_string() |> String.trim()

        policy_profiles =
          if next_cam == prev_cam do
            socket.assigns.policy_profiles
          else
            dependencies.list_relay_profiles.(scope, blank_to_nil(next_cam))
          end

        normalized =
          CameraRecordingSettings.normalize_policy_preview(
            socket.assigns.policy_form,
            policy_params,
            profiles: policy_profiles,
            policies: socket.assigns.policies,
            storage_mode: socket.assigns.storage_mode,
            configured_members: runtime_members(socket),
            entitlement: socket.assigns.entitlement
          )

        what_if =
          dependencies.what_if_policy_preview.(
            scope,
            normalized.form,
            policy_preview_opts(socket, policy_profiles)
          )

        {:noreply,
         socket
         |> refresh_scope_flags(scope)
         |> assign(:policy_profiles, policy_profiles)
         |> assign(:policy_form, normalized.form)
         |> assign(:policy_editing_revision, normalized.editing_revision)
         |> assign(:policy_errors, normalized.errors)
         |> assign(:policy_what_if, what_if)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Not authorized to manage recording policies")}
    end
  end

  def handle_event("save_policy", params, socket) do
    dependencies = deps(socket)

    case dependencies.authorize_current.(
           socket.assigns.current_scope,
           "settings.recording.manage"
         ) do
      {:ok, scope} ->
        raw_policy_params = Map.get(params, "policy", params)

        locked_defaults =
          Map.take(socket.assigns.policy_form, ["id", "camera_source_id", "stream_profile_id"])

        policy_params =
          if is_map(raw_policy_params) do
            Map.merge(locked_defaults, raw_policy_params, fn _k, default_v, submitted_v ->
              if submitted_v in [nil, ""], do: default_v, else: submitted_v
            end)
          else
            locked_defaults
          end

        case dependencies.save_policy.(scope, policy_params) do
          {:ok, saved} ->
            socket =
              socket
              |> refresh_scope_flags(scope)
              |> load_archive_data()
              |> load_policies_data()
              |> load_storage_and_health_data()

            cam_id = to_string(Map.get(saved, :camera_source_id) || "")
            policy_profiles = dependencies.list_relay_profiles.(scope, blank_to_nil(cam_id))
            saved_form = CameraRecordingSettings.policy_form_from_policy(saved, socket.assigns.storage_mode)
            rev = Map.get(saved, :policy_revision, 1)

            what_if =
              dependencies.what_if_policy_preview.(
                scope,
                saved_form,
                policy_preview_opts(socket, policy_profiles)
              )

            {:noreply,
             socket
             |> assign(:policy_profiles, policy_profiles)
             |> assign(:policy_form, saved_form)
             |> assign(:policy_editing_revision, rev)
             |> assign(:policy_errors, %{})
             |> assign(:policy_what_if, what_if)
             |> put_flash(:info, "Recording policy saved (revision #{rev})")}

          {:error, field_errors} ->
            normalized =
              CameraRecordingSettings.normalize_policy_preview(
                socket.assigns.policy_form,
                policy_params,
                profiles: socket.assigns.policy_profiles,
                policies: socket.assigns.policies,
                storage_mode: socket.assigns.storage_mode,
                configured_members: runtime_members(socket),
                entitlement: socket.assigns.entitlement
              )

            merged_errors = Map.merge(normalized.errors, normalize_error_map(field_errors))

            what_if =
              dependencies.what_if_policy_preview.(
                scope,
                normalized.form,
                policy_preview_opts(socket, socket.assigns.policy_profiles)
              )

            {:noreply,
             socket
             |> refresh_scope_flags(scope)
             |> assign(:policy_form, normalized.form)
             |> assign(:policy_editing_revision, normalized.editing_revision)
             |> assign(:policy_errors, merged_errors)
             |> assign(:policy_what_if, what_if)
             |> put_flash(:error, first_error_message(merged_errors, "Invalid recording policy"))}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Not authorized to manage recording policies")}
    end
  end

  def handle_event("select_storage_settings", params, socket) do
    dependencies = deps(socket)

    case dependencies.authorize_current.(
           socket.assigns.current_scope,
           "settings.recording.manage"
         ) do
      {:ok, scope} ->
        sid =
          (Map.get(params, "id") || Map.get(params, "storage_id") || "")
          |> to_string()
          |> String.trim()

        row = Enum.find(socket.assigns.storage_rows, &(&1.storage_id == sid))

        desired =
          if is_map(row) do
            row.desired_settings
          else
            NVRStorageSettings.default_storage_settings(sid)
          end

        {:noreply,
         socket
         |> refresh_scope_flags(scope)
         |> assign(
           :storage_settings_form,
           CameraRecordingSettings.storage_settings_form_from_record(desired)
         )
         |> assign(:storage_settings_errors, %{})}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Not authorized to manage NVR storage settings")}
    end
  end

  def handle_event("preview_storage_settings", params, socket) do
    dependencies = deps(socket)

    case dependencies.authorize_current.(
           socket.assigns.current_scope,
           "settings.recording.manage"
         ) do
      {:ok, scope} ->
        st_params = Map.get(params, "storage_settings", params)

        preview =
          CameraRecordingSettings.preview_storage_settings(
            st_params,
            prev_form: socket.assigns.storage_settings_form,
            health_summary: socket.assigns.health_summary,
            storage_rows: socket.assigns.storage_rows,
            scope: scope
          )

        {:noreply,
         socket
         |> refresh_scope_flags(scope)
         |> assign(:storage_settings_form, preview.form)
         |> assign(:storage_settings_errors, preview.errors)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Not authorized to manage NVR storage settings")}
    end
  end

  def handle_event("save_storage_settings", params, socket) do
    dependencies = deps(socket)

    case dependencies.authorize_current.(
           socket.assigns.current_scope,
           "settings.recording.manage"
         ) do
      {:ok, scope} ->
        st_params = Map.get(params, "storage_settings", params)
        sid = Map.get(st_params, "storage_id") || socket.assigns.storage_settings_form["storage_id"]

        case dependencies.save_storage_settings.(scope, sid, st_params) do
          {:ok, saved} ->
            rev = Map.get(saved, :revision, 1)

            {:noreply,
             socket
             |> refresh_scope_flags(scope)
             |> load_archive_data()
             |> load_storage_and_health_data()
             |> assign(
               :storage_settings_form,
               CameraRecordingSettings.storage_settings_form_from_record(saved)
             )
             |> assign(:storage_settings_errors, %{})
             |> put_flash(:info, "Storage settings saved (revision #{rev})")}

          {:error, field_errors} ->
            preview =
              CameraRecordingSettings.preview_storage_settings(
                st_params,
                prev_form: socket.assigns.storage_settings_form,
                health_summary: socket.assigns.health_summary,
                storage_rows: socket.assigns.storage_rows,
                scope: scope
              )

            merged_errors = Map.merge(preview.errors, normalize_error_map(field_errors))

            {:noreply,
             socket
             |> refresh_scope_flags(scope)
             |> assign(:storage_settings_form, preview.form)
             |> assign(:storage_settings_errors, merged_errors)
             |> put_flash(:error, first_error_message(merged_errors, "Invalid storage settings"))}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Not authorized to manage NVR storage settings")}
    end
  end

  def handle_event("request_quarantine_delete", params, socket) do
    dependencies = deps(socket)

    case dependencies.authorize_current.(
           socket.assigns.current_scope,
           "settings.recording.operate"
         ) do
      {:ok, scope} ->
        inner = Map.get(params, "delete", params)
        entry_id = to_string(Map.get(inner, "id") || Map.get(params, "id") || "")

        case dependencies.request_quarantine_delete.(scope, entry_id, inner) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> refresh_scope_flags(scope)
             |> load_archive_data()
             |> load_storage_and_health_data()
             |> maybe_reload_selected_camera()
             |> put_flash(:info, "Recorded audited delete intent for quarantined block")}

          {:error, message} ->
            {:noreply,
             socket
             |> refresh_scope_flags(scope)
             |> put_flash(:error, message)}
        end

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Not authorized to operate quarantined recordings (requires settings.recording.operate)"
         )}
    end
  end

  def handle_event("request_quarantine_export", params, socket) do
    dependencies = deps(socket)

    case dependencies.authorize_current.(
           socket.assigns.current_scope,
           "settings.recording.operate"
         ) do
      {:ok, scope} ->
        inner = Map.get(params, "export", params)
        entry_id = to_string(Map.get(inner, "id") || Map.get(params, "id") || "")

        case dependencies.request_quarantine_export.(scope, entry_id, inner) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> refresh_scope_flags(scope)
             |> load_storage_and_health_data()
             |> put_flash(:info, "Recorded audited export / preserve intent for quarantined block")}

          {:error, message} ->
            {:noreply,
             socket
             |> refresh_scope_flags(scope)
             |> put_flash(:error, message)}
        end

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Not authorized to operate quarantined recordings (requires settings.recording.operate)"
         )}
    end
  end

  def handle_event("accept_missing_archive_loss", params, socket) do
    dependencies = deps(socket)

    case dependencies.authorize_current.(
           socket.assigns.current_scope,
           "settings.recording.operate"
         ) do
      {:ok, scope} ->
        handle_authorized_accept_missing_loss(socket, scope, params, dependencies)

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Not authorized to accept missing archive copy loss (requires settings.recording.operate)"
         )}
    end
  end

  def handle_event("rearchive_missing_archive", params, socket) do
    dependencies = deps(socket)

    case dependencies.authorize_current.(
           socket.assigns.current_scope,
           "settings.recording.operate"
         ) do
      {:ok, scope} ->
        inner = Map.get(params, "rearchive", params)
        entry_id = to_string(Map.get(inner, "id") || Map.get(params, "id") || "")

        case dependencies.request_missing_archive_rearchive.(scope, entry_id, inner) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> refresh_scope_flags(scope)
             |> load_archive_data()
             |> load_storage_and_health_data()
             |> maybe_reload_selected_camera()
             |> put_flash(:info, "Queued missing archive copy for re-archive")}

          {:error, message} ->
            {:noreply,
             socket
             |> refresh_scope_flags(scope)
             |> put_flash(:error, message)}
        end

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Not authorized to re-archive missing copies (requires settings.recording.operate)"
         )}
    end
  end

  @impl true
  def handle_info({:vantage_worker_heartbeat, _payload}, socket) do
    if connected?(socket) do
      {:noreply, load_vantage_workers_data(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
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
        <section id="camera-recording-settings-page" class="space-y-5">
          <div>
            <h1 class="text-xl font-semibold text-sr-ink">Recording &amp; Storage</h1>
            <p class="mt-1 text-sm text-sr-muted">
              Inspect NVR installation and deployment recovery gate state, run local-only recording or
              configure immutable S3-compatible archive destinations and credentials, manage local and
              object retention settings, and review per-camera block locations.
            </p>
          </div>

          <Components.install_and_gate_banner
            runtime={@runtime}
            entitlement={@entitlement}
            active_tab={@active_tab}
          />

          <Components.tab_bar active_tab={@active_tab} />

          <Components.recorders_panel
            :if={@active_tab == "recorders"}
            runtime={@runtime}
            storage_mode={@storage_mode}
            can_manage?={@can_manage?}
            storage_rows={@storage_rows}
            storage_settings_form={@storage_settings_form}
            storage_settings_errors={@storage_settings_errors}
            timezone={user_timezone(@current_scope)}
          />

          <Components.archive_panel
            :if={@active_tab == "archive"}
            runtime={@runtime}
            storage_mode={@storage_mode}
            entitlement={@entitlement}
            bindings={@bindings}
            credentials={@credentials}
            can_manage?={@can_manage?}
            can_manage_credentials?={@can_manage_credentials?}
            settings_form={@settings_form}
            destination_form={@destination_form}
            destination_errors={@destination_errors}
            selected_writer_label={@selected_writer_label}
            selected_reader_label={@selected_reader_label}
            selected_retention_label={@selected_retention_label}
            object_retention_enforced?={@object_retention_enforced?}
            credential_issue={@credential_issue}
            active_binding_id={@active_binding_id}
            active_binding_managed_by_cloud?={@active_binding_managed_by_cloud?}
            writer_managed_by_cloud?={@writer_managed_by_cloud?}
            reader_managed_by_cloud?={@reader_managed_by_cloud?}
            retention_managed_by_cloud?={@retention_managed_by_cloud?}
          />

          <Components.cameras_panel
            :if={@active_tab == "cameras"}
            runtime={@runtime}
            sources={@sources}
            profiles={@profiles}
            sources_forbidden?={@sources_forbidden?}
            selected_camera_id={@selected_camera_id}
            selected_profile_id={@selected_profile_id}
            blocks_loaded?={@blocks_loaded?}
            blocks_empty?={@blocks_empty?}
            blocks_filtered_more?={@blocks_filtered_more?}
            blocks_next_cursor={@blocks_next_cursor}
            streams={@streams}
            timezone={user_timezone(@current_scope)}
          />

          <Components.policy_panel
            :if={@active_tab == "policy"}
            runtime={@runtime}
            storage_mode={@storage_mode}
            entitlement={@entitlement}
            can_manage?={@can_manage?}
            sources={@sources}
            sources_forbidden?={@sources_forbidden?}
            policies={@policies}
            recording_now={@recording_now}
            policy_profiles={@policy_profiles}
            policy_form={@policy_form}
            policy_editing_revision={@policy_editing_revision}
            policy_errors={@policy_errors}
            policy_what_if={@policy_what_if}
          />

          <Components.retention_panel
            :if={@active_tab == "retention"}
            storage_mode={@storage_mode}
            entitlement={@entitlement}
            can_manage?={@can_manage?}
            settings_record={@settings_record}
            settings_struct={@settings_struct}
            retention_form={@retention_form}
            simulator_form={@simulator_form}
            retention_errors={@retention_errors}
            usage_summary={@usage_summary}
            projection={@retention_projection}
            object_retention_enforced?={@object_retention_enforced?}
            selected_retention_label={@selected_retention_label}
            timezone={user_timezone(@current_scope)}
          />

          <Components.health_panel
            :if={@active_tab == "health"}
            runtime={@runtime}
            storage_mode={@storage_mode}
            can_operate?={@can_operate?}
            can_hold?={@can_hold?}
            health_summary={@health_summary}
            vantage_worker_summary={@vantage_worker_summary}
            timezone={user_timezone(@current_scope)}
          />
        </section>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  # --- internal helpers ------------------------------------------------------

  defp deps(socket) do
    Map.merge(default_deps(), Map.get(socket.assigns, :recording_deps, %{}))
  end

  defp default_deps do
    %{
      runtime_status: &CameraRecordingRuntime.status/0,
      authorize_current: &RBAC.authorize_current/2,
      authorize_current_any: &RBAC.authorize_current_any/2,
      list_archive_bindings: &CameraRecordingSettings.list_archive_bindings/1,
      list_enabled_s3_credentials: &CameraRecordingSettings.list_enabled_s3_credentials/1,
      load_archive_settings_view: &CameraRecordingSettings.load_archive_settings_view/1,
      load_retention_usage_summary: &CameraRecordingSettings.load_retention_usage_summary/1,
      register_operator_destination: &CameraRecordingSettings.register_operator_destination/2,
      save_archive_settings: &CameraRecordingSettings.save_archive_settings/3,
      save_retention_settings: &CameraRecordingSettings.save_retention_settings/2,
      list_camera_sources: &CameraRecordingSettings.list_camera_sources/1,
      list_relay_profiles: &CameraRecordingSettings.list_relay_profiles/2,
      list_camera_blocks_page: &CameraRecordingSettings.list_camera_blocks_page/3,
      list_policies: &CameraRecordingSettings.list_policies/1,
      recording_now: &CameraRecordingSettings.recording_now/1,
      save_policy: &CameraRecordingSettings.save_policy/2,
      what_if_policy_preview: &CameraRecordingSettings.what_if_policy_preview/3,
      list_storage_settings: &CameraRecordingSettings.list_storage_settings/1,
      save_storage_settings: &CameraRecordingSettings.save_storage_settings/3,
      fetch_nvr_member_statuses: &CameraRecordingRuntime.member_statuses/1,
      load_recording_health: &CameraRecordingSettings.load_recording_health/2,
      load_vantage_worker_summary: &CameraVantageWorkers.summary/1,
      request_quarantine_delete: &CameraRecordingSettings.request_quarantine_delete/3,
      request_quarantine_export: &CameraRecordingSettings.request_quarantine_export/3,
      accept_missing_archive_loss: &CameraRecordingSettings.accept_missing_archive_loss/3,
      request_missing_archive_rearchive: &CameraRecordingSettings.request_missing_archive_rearchive/3
    }
  end

  defp initial_runtime do
    %{
      recovery_gate: %{state: :unknown, generation: nil},
      core_elx: %{
        reachability: :unknown,
        node: nil,
        supervisor: :unknown,
        nvr_installation: :unknown,
        members: []
      }
    }
  end

  defp load_connected_data(socket) do
    dependencies = deps(socket)

    socket
    |> maybe_subscribe_vantage_workers()
    |> assign(:runtime, dependencies.runtime_status.())
    |> load_archive_data()
    |> load_cameras_data()
    |> load_policies_data()
    |> load_storage_and_health_data()
    |> load_vantage_workers_data()
  end

  defp maybe_subscribe_vantage_workers(%{assigns: %{vantage_worker_subscribed?: true}} = socket), do: socket

  defp maybe_subscribe_vantage_workers(socket) do
    _ = VantagePubSub.subscribe_worker_health()
    assign(socket, :vantage_worker_subscribed?, true)
  end

  defp load_vantage_workers_data(socket) do
    dependencies = deps(socket)
    summary = dependencies.load_vantage_worker_summary.(socket.assigns.current_scope)
    assign(socket, :vantage_worker_summary, summary)
  end

  defp load_archive_data(socket) do
    scope = socket.assigns.current_scope
    dependencies = deps(socket)
    bindings = dependencies.list_archive_bindings.(scope)
    credentials = dependencies.list_enabled_s3_credentials.(scope)
    settings_view = dependencies.load_archive_settings_view.(scope)
    usage_summary = dependencies.load_retention_usage_summary.(scope)

    settings_struct =
      Map.get(settings_view, :settings) ||
        Map.get(settings_view, :record) ||
        RecordingArchiveSettings.default_settings()

    entitlement =
      CameraRecordingSettings.normalize_entitlement_view(Map.get(settings_view, :entitlement))

    storage_mode = Map.get(settings_view, :storage_mode, :local_only)

    retention_form =
      Map.get_lazy(settings_view, :retention_form, fn ->
        CameraRecordingSettings.retention_form_from_settings(settings_struct, entitlement)
      end)

    object_retention_enforced? =
      Map.get(
        settings_view,
        :object_retention_enforced?,
        Map.get(usage_summary, :object_retention_enforced?, false)
      )

    preview =
      CameraRecordingSettings.preview_retention_settings(
        %{},
        socket.assigns.simulator_form,
        prev_form: retention_form,
        prev_simulator: socket.assigns.simulator_form,
        usage_summary: usage_summary,
        existing: Map.get(settings_view, :record),
        storage_mode: storage_mode,
        entitlement: entitlement,
        scope: scope
      )

    active_binding_cloud? =
      Map.get_lazy(settings_view, :active_binding_managed_by_cloud?, fn ->
        active_id = Map.get(settings_view, :active_binding_id)

        case Enum.find(bindings, &(to_string(Map.get(&1, :id)) == to_string(active_id))) do
          %{provisioning_ref: ref} when is_binary(ref) ->
            ref != "" and not String.starts_with?(ref, "operator:")

          _ ->
            false
        end
      end)

    socket
    |> assign(:bindings, bindings)
    |> assign(:credentials, credentials)
    |> assign(:settings_record, Map.get(settings_view, :record))
    |> assign(:settings_struct, settings_struct)
    |> assign(:entitlement, entitlement)
    |> assign(:storage_mode, storage_mode)
    |> assign(:settings_form, settings_view.form)
    |> assign(:retention_form, retention_form)
    |> assign(:usage_summary, usage_summary)
    |> assign(:retention_projection, preview.projection)
    |> assign(:active_binding_id, settings_view.active_binding_id)
    |> assign(:active_binding_managed_by_cloud?, active_binding_cloud?)
    |> assign(:writer_managed_by_cloud?, Map.get(settings_view, :writer_managed_by_cloud?, false))
    |> assign(:reader_managed_by_cloud?, Map.get(settings_view, :reader_managed_by_cloud?, false))
    |> assign(:retention_managed_by_cloud?, Map.get(settings_view, :retention_managed_by_cloud?, false))
    |> assign(:selected_writer_label, settings_view.selected_writer_label)
    |> assign(:selected_reader_label, settings_view.selected_reader_label)
    |> assign(
      :selected_retention_label,
      Map.get(
        settings_view,
        :selected_retention_label,
        "None selected (object retention not enforced)"
      )
    )
    |> assign(:object_retention_enforced?, object_retention_enforced?)
    |> assign(:credential_issue, settings_view.credential_issue)
  end

  defp load_cameras_data(socket) do
    scope = socket.assigns.current_scope
    dependencies = deps(socket)

    {sources, forbidden?} =
      case dependencies.list_camera_sources.(scope) do
        {:ok, list} -> {list, false}
        {:forbidden, []} -> {[], true}
      end

    socket
    |> assign(:sources, sources)
    |> assign(:sources_forbidden?, forbidden?)
    |> maybe_reload_selected_camera()
  end

  defp load_policies_data(socket) do
    scope = socket.assigns.current_scope
    dependencies = deps(socket)
    policies = dependencies.list_policies.(scope)

    current_form = socket.assigns.policy_form

    base_form =
      if current_form["id"] == "" and current_form["camera_source_id"] == "" do
        CameraRecordingSettings.default_policy_form(socket.assigns.storage_mode)
      else
        current_form
      end

    cam_id = blank_to_nil(base_form["camera_source_id"])

    policy_profiles =
      cond do
        is_nil(cam_id) ->
          []

        socket.assigns.policy_profiles != [] ->
          socket.assigns.policy_profiles

        true ->
          dependencies.list_relay_profiles.(scope, cam_id)
      end

    next_form = sync_policy_form_profile(base_form, policy_profiles)

    socket =
      socket
      |> assign(:policies, policies)
      |> assign(:recording_now, dependencies.recording_now.(scope))
      |> assign(:policy_profiles, policy_profiles)
      |> assign(:policy_form, next_form)

    what_if =
      dependencies.what_if_policy_preview.(
        scope,
        next_form,
        policy_preview_opts(socket, policy_profiles)
      )

    assign(socket, :policy_what_if, what_if)
  end

  defp sync_policy_form_profile(form, profiles) when is_map(form) and is_list(profiles) do
    cam_id = form["camera_source_id"] || ""
    prof_id = form["stream_profile_id"] || ""

    cond do
      cam_id == "" or profiles == [] ->
        form

      Enum.any?(profiles, &(to_string(Map.get(&1, :id)) == prof_id)) ->
        form

      true ->
        Map.put(form, "stream_profile_id", to_string(List.first(profiles).id))
    end
  end

  defp load_storage_and_health_data(socket) do
    scope = socket.assigns.current_scope
    dependencies = deps(socket)
    storage_settings_rows = dependencies.list_storage_settings.(scope)
    members = runtime_members(socket)

    known_storage_ids =
      members
      |> Enum.map(&to_string(Map.get(&1, :storage_id, "")))
      |> Enum.reject(&(&1 == ""))

    member_by_storage_id =
      Enum.reduce(members, %{}, fn m, acc ->
        sid = to_string(Map.get(m, :storage_id, ""))
        name = Map.get(m, :member)
        if sid != "" and is_binary(name) and name != "", do: Map.put(acc, sid, name), else: acc
      end)

    live_statuses =
      case dependencies.fetch_nvr_member_statuses do
        fun when is_function(fun, 1) -> safe_live_statuses(fun.(socket.assigns.runtime))
        fun when is_function(fun, 0) -> safe_live_statuses(fun.())
        _ -> %{}
      end

    member_measurements = CameraRecordingSettings.member_measurements_from_statuses(live_statuses)

    health_opts = [
      known_storage_ids: known_storage_ids,
      member_by_storage_id: member_by_storage_id,
      member_measurements: member_measurements
    ]

    raw_health_summary =
      case dependencies.load_recording_health do
        fun when is_function(fun, 2) -> fun.(scope, health_opts)
        fun when is_function(fun, 1) -> fun.(scope)
      end

    storage_rows =
      CameraRecordingSettings.merge_storage_member_rows(
        storage_settings_rows,
        raw_health_summary,
        members
      )

    health_summary =
      raw_health_summary
      |> CameraRecordingSettings.enrich_health_with_storage_rows(storage_rows)
      |> CameraRecordingSettings.attach_live_statuses(live_statuses)

    next_st_form =
      if socket.assigns.storage_settings_form["storage_id"] == "" and storage_rows != [] do
        storage_rows
        |> hd()
        |> Map.get(:desired_settings)
        |> CameraRecordingSettings.storage_settings_form_from_record()
      else
        socket.assigns.storage_settings_form
      end

    socket
    |> assign(:storage_settings_rows, storage_settings_rows)
    |> assign(:health_summary, health_summary)
    |> assign(:storage_rows, storage_rows)
    |> assign(:storage_settings_form, next_st_form)
  end

  defp safe_live_statuses(%{} = statuses), do: statuses
  defp safe_live_statuses(_), do: %{}

  defp runtime_members(socket) do
    socket.assigns
    |> Map.get(:runtime, %{})
    |> Map.get(:core_elx, %{})
    |> Map.get(:members, [])
  end

  defp policy_preview_opts(socket, policy_profiles) do
    [
      settings: socket.assigns.settings_struct,
      profiles: policy_profiles
    ]
  end

  defp maybe_reload_selected_camera(socket) do
    case socket.assigns.selected_camera_id do
      id when is_binary(id) and id != "" ->
        select_camera_and_load_blocks(socket, id, socket.assigns.selected_profile_id)

      _ ->
        socket
    end
  end

  defp maybe_apply_camera_param(socket, nil), do: socket
  defp maybe_apply_camera_param(socket, ""), do: socket

  defp maybe_apply_camera_param(socket, camera_id) when is_binary(camera_id) do
    if connected?(socket) do
      select_camera_and_load_blocks(socket, camera_id, nil)
    else
      assign(socket, :selected_camera_id, camera_id)
    end
  end

  defp select_camera_and_load_blocks(socket, nil, _profile_id) do
    socket
    |> assign(:selected_camera_id, nil)
    |> assign(:selected_profile_id, nil)
    |> assign(:profiles, [])
    |> assign(:blocks_loaded?, false)
    |> assign(:blocks_stream_count, 0)
    |> assign(:blocks_empty?, true)
    |> assign(:blocks_filtered_more?, false)
    |> assign(:blocks_next_cursor, nil)
    |> stream(:recording_blocks, [], reset: true)
  end

  defp select_camera_and_load_blocks(socket, camera_id, profile_id) do
    scope = socket.assigns.current_scope
    dependencies = deps(socket)
    profiles = dependencies.list_relay_profiles.(scope, camera_id)

    valid_profile_id =
      if Enum.any?(profiles, &(to_string(&1.id) == to_string(profile_id))), do: profile_id

    {:ok, page} =
      dependencies.list_camera_blocks_page.(scope, camera_id, stream_profile_id: valid_profile_id)

    count = length(page.rows)

    socket
    |> assign(:selected_camera_id, camera_id)
    |> assign(:selected_profile_id, valid_profile_id)
    |> assign(:profiles, profiles)
    |> assign(:blocks_loaded?, true)
    |> assign(:blocks_stream_count, count)
    |> assign(:blocks_empty?, count == 0 and is_nil(page.next_cursor))
    |> assign(:blocks_filtered_more?, count == 0 and not is_nil(page.next_cursor))
    |> assign(:blocks_next_cursor, page.next_cursor)
    |> stream(:recording_blocks, page.rows, reset: true)
  end

  defp authorize_any_recording_permission(socket) do
    dependencies = deps(socket)

    case dependencies.authorize_current_any.(
           socket.assigns.current_scope,
           @recording_permissions
         ) do
      {:ok, scope} ->
        {:ok, scope}

      {:error, _reason} ->
        {:error,
         socket
         |> put_flash(:error, "Your camera recording settings permission was revoked")
         |> redirect(to: ~p"/settings/profile")}
    end
  end

  defp handle_authorized_accept_missing_loss(socket, scope, params, dependencies) do
    inner = Map.get(params, "loss", params)
    entry_id = to_string(Map.get(inner, "id") || Map.get(params, "id") || "")

    can_hold? =
      match?(
        {:ok, _},
        dependencies.authorize_current.(scope, "devices.cameras.recordings.hold")
      )

    if missing_entry_held?(socket.assigns.health_summary, entry_id) and not can_hold? do
      {:noreply,
       socket
       |> refresh_scope_flags(scope)
       |> assign(:can_hold?, false)
       |> put_flash(
         :error,
         "Accepting archive loss on a held recording requires devices.cameras.recordings.hold"
       )}
    else
      effective_scope = enforce_hold_flag_on_scope(scope, can_hold?)

      case dependencies.accept_missing_archive_loss.(effective_scope, entry_id, inner) do
        {:ok, _result} ->
          {:noreply,
           socket
           |> refresh_scope_flags(scope)
           |> assign(:can_hold?, can_hold?)
           |> load_archive_data()
           |> load_storage_and_health_data()
           |> maybe_reload_selected_camera()
           |> put_flash(:info, "Accepted missing archive copy loss (audited disposition recorded)")}

        {:error, message} ->
          {:noreply,
           socket
           |> refresh_scope_flags(scope)
           |> assign(:can_hold?, can_hold?)
           |> put_flash(:error, message)}
      end
    end
  end

  defp missing_entry_held?(health_summary, entry_id) when is_map(health_summary) do
    top_entries = Map.get(health_summary, :missing_archive_entries, [])
    backlog_entries = health_summary |> Map.get(:archive_backlog, %{}) |> Map.get(:missing_entries, [])

    Enum.any?(top_entries ++ backlog_entries, fn item ->
      item_id = to_string(Map.get(item, :id) || Map.get(item, :catalog_entry_id) || "")

      item_id == entry_id and
        (Map.get(item, :held?) == true or Map.get(item, :requires_hold_permission?) == true)
    end)
  end

  defp missing_entry_held?(_health_summary, _entry_id), do: false

  defp enforce_hold_flag_on_scope(%{permissions: %MapSet{} = perms} = scope, false) do
    %{scope | permissions: MapSet.delete(perms, "devices.cameras.recordings.hold")}
  end

  defp enforce_hold_flag_on_scope(scope, _can_hold?), do: scope

  defp refresh_scope_flags(socket, scope) do
    socket
    |> assign(:current_scope, scope)
    |> assign(:can_manage?, RBAC.can?(scope, "settings.recording.manage"))
    |> assign(:can_operate?, RBAC.can?(scope, "settings.recording.operate"))
    |> assign(:can_hold?, RBAC.can?(scope, "devices.cameras.recordings.hold"))
    |> assign(:can_manage_credentials?, RBAC.can?(scope, "settings.credentials.manage"))
  end

  defp normalize_error_map(errors) when is_map(errors), do: errors
  defp normalize_error_map(msg) when is_binary(msg), do: %{base: msg}
  defp normalize_error_map(other), do: %{base: inspect(other)}

  defp first_error_message(errors, fallback) when is_map(errors) do
    case Map.get(errors, :base) do
      msg when is_binary(msg) and msg != "" ->
        msg

      _ ->
        case Enum.at(errors, 0) do
          {field, msg} -> "#{field}: #{msg}"
          nil -> fallback
        end
    end
  end

  defp normalize_tab(tab) when tab in @supported_tabs, do: tab
  defp normalize_tab(_tab), do: "recorders"

  defp user_timezone(%{user: %{timezone: tz}}) when is_binary(tz) and tz != "", do: tz
  defp user_timezone(_scope), do: "Etc/UTC"

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(val) when is_binary(val) do
    case String.trim(val) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
