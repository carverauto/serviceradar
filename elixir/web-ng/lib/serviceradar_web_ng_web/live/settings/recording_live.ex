defmodule ServiceRadarWebNGWeb.Settings.RecordingLive do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.CameraRecordingRuntime
  alias ServiceRadarWebNG.CameraRecordingSettings
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.RecordingLive.Components
  alias ServiceRadarWebNGWeb.Settings.Shell

  @path "/settings/recording"
  @supported_tabs ~w(recorders archive cameras policy health)
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
      socket =
        socket
        |> assign(:page_title, "Recording & Storage")
        |> assign(:current_path, @path)
        |> assign(:active_tab, "recorders")
        |> assign(:can_manage?, RBAC.can?(scope, "settings.recording.manage"))
        |> assign(:can_operate?, RBAC.can?(scope, "settings.recording.operate"))
        |> assign(:can_manage_credentials?, RBAC.can?(scope, "settings.credentials.manage"))
        |> assign(:runtime, initial_runtime())
        |> assign(:bindings, [])
        |> assign(:credentials, [])
        |> assign(:settings_form, CameraRecordingSettings.default_settings_form())
        |> assign(:destination_form, CameraRecordingSettings.default_destination_form())
        |> assign(:destination_errors, %{})
        |> assign(:active_binding_id, nil)
        |> assign(:selected_writer_label, "None selected")
        |> assign(:selected_reader_label, "Use writer credential (reader role)")
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
              Inspect NVR installation and deployment recovery gate state, manage immutable S3-compatible
              archive destinations and credentials, and review per-camera block locations.
            </p>
          </div>

          <Components.install_and_gate_banner runtime={@runtime} />

          <Components.tab_bar active_tab={@active_tab} />

          <Components.recorders_panel :if={@active_tab == "recorders"} runtime={@runtime} />

          <Components.archive_panel
            :if={@active_tab == "archive"}
            runtime={@runtime}
            bindings={@bindings}
            credentials={@credentials}
            can_manage?={@can_manage?}
            can_manage_credentials?={@can_manage_credentials?}
            settings_form={@settings_form}
            destination_form={@destination_form}
            destination_errors={@destination_errors}
            selected_writer_label={@selected_writer_label}
            selected_reader_label={@selected_reader_label}
            credential_issue={@credential_issue}
            active_binding_id={@active_binding_id}
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

          <Components.policy_blocked_panel :if={@active_tab == "policy"} />

          <Components.health_blocked_panel :if={@active_tab == "health"} />
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
      register_operator_destination: &CameraRecordingSettings.register_operator_destination/2,
      save_archive_settings: &CameraRecordingSettings.save_archive_settings/3,
      list_camera_sources: &CameraRecordingSettings.list_camera_sources/1,
      list_relay_profiles: &CameraRecordingSettings.list_relay_profiles/2,
      list_camera_blocks_page: &CameraRecordingSettings.list_camera_blocks_page/3
    }
  end

  defp initial_runtime do
    %{
      recovery_gate: %{state: :unknown, generation: nil},
      core_elx: %{
        reachability: :unknown,
        node: nil,
        supervisor: :unknown,
        nvr_installation: :unknown
      }
    }
  end

  defp load_connected_data(socket) do
    dependencies = deps(socket)

    socket
    |> assign(:runtime, dependencies.runtime_status.())
    |> load_archive_data()
    |> load_cameras_data()
  end

  defp load_archive_data(socket) do
    scope = socket.assigns.current_scope
    dependencies = deps(socket)
    bindings = dependencies.list_archive_bindings.(scope)
    credentials = dependencies.list_enabled_s3_credentials.(scope)
    settings_view = dependencies.load_archive_settings_view.(scope)

    socket
    |> assign(:bindings, bindings)
    |> assign(:credentials, credentials)
    |> assign(:settings_form, settings_view.form)
    |> assign(:active_binding_id, settings_view.active_binding_id)
    |> assign(:selected_writer_label, settings_view.selected_writer_label)
    |> assign(:selected_reader_label, settings_view.selected_reader_label)
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

  defp refresh_scope_flags(socket, scope) do
    socket
    |> assign(:current_scope, scope)
    |> assign(:can_manage?, RBAC.can?(scope, "settings.recording.manage"))
    |> assign(:can_operate?, RBAC.can?(scope, "settings.recording.operate"))
    |> assign(:can_manage_credentials?, RBAC.can?(scope, "settings.credentials.manage"))
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
