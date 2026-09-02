defmodule ServiceRadarWebNGWeb.Settings.RemoteAccessRecordingsLive do
  @moduledoc """
  Operator replay page for remote-access session recordings.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Edge.RemoteAccessRecording
  alias ServiceRadar.Edge.RemoteAccessRecordings
  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Ash.Query

  @current_path "/settings/networks/recordings"
  @ssh_view_permission "devices.remote_access.ssh.open"
  @rdp_view_permission "devices.remote_access.rdp.open"
  @view_permissions [@ssh_view_permission, @rdp_view_permission]
  @export_permission "devices.remote_access.recordings.export"
  @view_all_permission "devices.remote_access.recordings.view_all"
  @list_limit 100

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if can_view?(scope) do
      {:ok,
       socket
       |> assign(:page_title, "Remote Access Recordings")
       |> assign(:current_path, @current_path)
       |> assign(:recordings, [])
       |> assign(:selected_recording, nil)
       |> assign(:events, [])
       |> assign(:loading?, true)
       |> assign(:can_export?, can_export?(scope))}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to view remote access recordings")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if fresh_can_view?(socket.assigns.current_scope) do
      socket =
        socket
        |> assign(:current_path, @current_path)
        |> assign(:can_export?, can_export?(socket.assigns.current_scope))

      if connected?(socket) do
        {:noreply, load_recordings(socket, params["id"])}
      else
        {:noreply, socket}
      end
    else
      {:noreply, unauthorized(socket)}
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
        <section class="space-y-5">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h1 class="text-xl font-semibold">Remote Access Recordings</h1>
              <p class="mt-1 text-sm text-sr-muted">
                Review replay manifests and captured session events.
              </p>
            </div>
            <.ui_button
              :if={@selected_recording && @can_export?}
              variant="outline"
              size="sm"
              href={~p"/api/remote-access/recordings/#{@selected_recording.id}/export"}
              target="_blank"
              rel="noopener"
            >
              Export
            </.ui_button>
          </div>

          <div class="grid gap-4 lg:grid-cols-[minmax(20rem,24rem)_1fr]">
            <aside class="overflow-hidden rounded-lg border border-sr-line bg-sr-surface">
              <div class="border-b border-sr-line px-4 py-3">
                <h2 class="text-sm font-semibold">Recent Recordings</h2>
              </div>
              <div class="max-h-[42rem] overflow-y-auto">
                <div :if={@loading?} class="px-4 py-8 text-center text-sm text-sr-muted">
                  Loading recordings.
                </div>
                <div
                  :if={!@loading? and @recordings == []}
                  class="px-4 py-8 text-center text-sm text-sr-muted"
                >
                  No recordings found.
                </div>
                <.link
                  :for={recording <- @recordings}
                  navigate={~p"/settings/networks/recordings/#{recording.id}"}
                  class={[
                    "block border-b border-sr-line px-4 py-3 transition hover:bg-sr-subtle/60",
                    selected?(@selected_recording, recording) && "bg-sr-brand/10"
                  ]}
                >
                  <div class="flex items-center justify-between gap-3">
                    <span class="font-mono text-xs">{short_id(recording.session_id)}</span>
                    <.ui_badge size="sm" variant={status_badge_variant(recording.status)}>
                      {label(recording.status)}
                    </.ui_badge>
                  </div>
                  <div class="mt-1 truncate text-sm font-medium">{target_label(recording)}</div>
                  <div class="mt-1 text-xs text-sr-muted">
                    <.user_time
                      id={"settings-remote-access-recording-#{recording.id}-list-started-at"}
                      value={recording.started_at || recording.inserted_at}
                      timezone={@current_scope.user.timezone || "Etc/UTC"}
                      style={:compact}
                      fallback="-"
                    />
                  </div>
                </.link>
              </div>
            </aside>

            <div class="space-y-4">
              <div
                :if={!@selected_recording}
                class="rounded-lg border border-sr-line bg-sr-surface p-8 text-center text-sm text-sr-muted"
              >
                Select a recording.
              </div>

              <.recording_summary
                :if={@selected_recording}
                recording={@selected_recording}
                timezone={@current_scope.user.timezone || "Etc/UTC"}
              />
              <.event_timeline
                :if={@selected_recording}
                events={@events}
                timezone={@current_scope.user.timezone || "Etc/UTC"}
              />
            </div>
          </div>
        </section>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  attr(:recording, :any, required: true)
  attr(:timezone, :string, required: true)

  defp recording_summary(assigns) do
    ~H"""
    <section class="rounded-lg border border-sr-line bg-sr-surface p-4">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h2 class="text-lg font-semibold">{target_label(@recording)}</h2>
          <p class="mt-1 font-mono text-xs text-sr-muted">Session {@recording.session_id}</p>
        </div>
        <.ui_badge size="sm" variant={status_badge_variant(@recording.status)}>
          {label(@recording.status)}
        </.ui_badge>
      </div>

      <dl class="mt-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <.summary_item label="Events" value={@recording.event_count} />
        <.summary_item label="Input bytes" value={@recording.input_bytes} />
        <.summary_item label="Output bytes" value={@recording.output_bytes} />
        <.timestamp_summary_item
          id={"settings-remote-access-recording-#{@recording.id}-retention-expires-at"}
          label="Retention"
          value={@recording.retention_expires_at}
          timezone={@timezone}
        />
        <.timestamp_summary_item
          id={"settings-remote-access-recording-#{@recording.id}-started-at"}
          label="Started"
          value={@recording.started_at}
          timezone={@timezone}
        />
        <.timestamp_summary_item
          id={"settings-remote-access-recording-#{@recording.id}-completed-at"}
          label="Completed"
          value={@recording.completed_at}
          timezone={@timezone}
        />
        <.summary_item label="Failure" value={@recording.failure_reason || "-"} />
      </dl>

      <div class="mt-4">
        <div>
          <div class="text-xs font-semibold uppercase text-sr-muted">Content</div>
          <div class="mt-1 text-sm">{content_label(@recording.manifest)}</div>
        </div>
      </div>

      <div :if={desktop_recording?(@recording)} class="mt-4">
        <div class="text-xs font-semibold uppercase text-sr-muted">
          Desktop Policy Snapshot
        </div>
        <dl class="mt-2 grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
          <.summary_item
            :for={item <- desktop_policy_items(@recording)}
            label={item.label}
            value={item.value}
          />
        </dl>
      </div>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  defp summary_item(assigns) do
    ~H"""
    <div class="rounded-md border border-sr-line bg-sr-subtle/40 p-3">
      <dt class="text-xs font-semibold uppercase text-sr-muted">{@label}</dt>
      <dd class="mt-1 break-words text-sm font-medium">{@value}</dd>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:timezone, :string, required: true)

  defp timestamp_summary_item(assigns) do
    ~H"""
    <div class="rounded-md border border-sr-line bg-sr-subtle/40 p-3">
      <dt class="text-xs font-semibold uppercase text-sr-muted">{@label}</dt>
      <dd class="mt-1 break-words text-sm font-medium">
        <.user_time
          id={@id}
          value={@value}
          timezone={@timezone}
          style={:compact}
          fallback="-"
        />
      </dd>
    </div>
    """
  end

  attr(:events, :list, required: true)
  attr(:timezone, :string, required: true)

  defp event_timeline(assigns) do
    ~H"""
    <section class="overflow-hidden rounded-lg border border-sr-line bg-sr-surface">
      <div class="border-b border-sr-line px-4 py-3">
        <h2 class="text-sm font-semibold">Replay Events</h2>
      </div>
      <div :if={@events == []} class="px-4 py-8 text-center text-sm text-sr-muted">
        No replay events stored.
      </div>
      <div :for={event <- @events} class="border-b border-sr-line p-4 last:border-b-0">
        <div class="flex flex-wrap items-center gap-2">
          <.ui_badge size="sm" variant="ghost">{event.sequence}</.ui_badge>
          <.ui_badge size="sm" variant={stream_badge_variant(event.stream)}>
            {label(event.stream)}
          </.ui_badge>
          <span class="text-sm font-medium">{event.event_type}</span>
          <span class="text-xs text-sr-muted">
            <.user_time
              id={"settings-remote-access-recording-event-#{event.id}-occurred-at"}
              value={event.occurred_at}
              timezone={@timezone}
              style={:compact}
              fallback="-"
            />
          </span>
          <.ui_badge :if={event.payload_redacted} size="sm" variant="warning">
            {redaction_label(event.redaction_reason)}
          </.ui_badge>
        </div>
        <pre
          :if={event.payload_text}
          class="mt-3 max-h-72 overflow-auto rounded-md bg-sr-subtle p-3 text-xs whitespace-pre-wrap"
        ><%= event.payload_text %></pre>
        <div :if={!event.payload_text} class="mt-3 text-sm text-sr-muted">
          Payload text not stored. {event.byte_count} bytes, SHA-256 {event.payload_sha256 || "-"}.
        </div>
        <details :if={event.metadata != %{}} class="mt-3">
          <summary class="cursor-pointer text-xs font-semibold uppercase text-sr-muted">
            Metadata
          </summary>
          <pre class="mt-2 max-h-60 overflow-auto rounded-md bg-sr-subtle p-3 text-xs"><%= Jason.encode!(event.metadata, pretty: true) %></pre>
        </details>
      </div>
    </section>
    """
  end

  defp load_recordings(socket, selected_id) do
    case list_recent(socket.assigns.current_scope) do
      {:ok, recordings} ->
        recordings = Enum.filter(recordings, &recording_view_allowed?(socket.assigns.current_scope, &1))

        socket
        |> assign(:recordings, recordings)
        |> assign(:loading?, false)
        |> load_selected(selected_id, recordings)

      {:error, reason} ->
        socket
        |> assign(:recordings, [])
        |> assign(:selected_recording, nil)
        |> assign(:events, [])
        |> assign(:loading?, false)
        |> put_flash(:error, "Failed to load recordings: #{format_error(reason)}")
    end
  end

  defp load_selected(socket, nil, _recordings) do
    socket
    |> assign(:selected_recording, nil)
    |> assign(:events, [])
  end

  defp load_selected(socket, id, recordings) do
    scope = socket.assigns.current_scope

    with {:ok, normalized_id} <- normalize_uuid(id),
         {:ok, %RemoteAccessRecording{} = recording} <-
           get_recording(normalized_id, recordings, scope),
         :ok <- ensure_recording_allowed(recording, scope),
         {:ok, events} <- RemoteAccessRecordings.list_events(recording, scope: scope) do
      socket
      |> assign(:selected_recording, recording)
      |> assign(:events, events)
    else
      {:error, :invalid_id} ->
        socket
        |> assign(:selected_recording, nil)
        |> assign(:events, [])
        |> put_flash(:error, "Recording ID is invalid")

      {:error, :not_found} ->
        socket
        |> assign(:selected_recording, nil)
        |> assign(:events, [])
        |> put_flash(:error, "Recording was not found")

      {:error, reason} ->
        socket
        |> assign(:selected_recording, nil)
        |> assign(:events, [])
        |> put_flash(:error, "Failed to load recording: #{format_error(reason)}")
    end
  end

  defp list_recent(scope) do
    RemoteAccessRecording
    |> Ash.Query.for_read(:read)
    |> Ash.Query.load(:session)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(@list_limit)
    |> Ash.read(scope: scope)
  end

  defp get_recording(id, recordings, scope) do
    case Enum.find(recordings, &(&1.id == id)) do
      %RemoteAccessRecording{} = recording ->
        {:ok, recording}

      nil ->
        case_result =
          case RemoteAccessRecording.get_by_id(id, scope: scope) do
            {:ok, %RemoteAccessRecording{} = recording} -> {:ok, recording}
            {:ok, nil} -> {:error, :not_found}
            {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
            {:error, reason} -> {:error, reason}
          end

        load_recording_session(case_result, scope)
    end
  end

  defp load_recording_session({:ok, %RemoteAccessRecording{} = recording}, scope) do
    Ash.load(recording, :session, scope: scope)
  end

  defp load_recording_session(result, _scope), do: result

  defp normalize_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :invalid_id}
    end
  end

  defp unauthorized(socket) do
    socket
    |> put_flash(:error, "Not authorized to view remote access recordings")
    |> redirect(to: ~p"/settings/profile")
  end

  defp fresh_can_view?(%{user: user}) when not is_nil(user) do
    ServiceRadar.Identity.RBAC.clear_process_cache()
    Enum.any?(@view_permissions, &ServiceRadar.Identity.RBAC.has_permission?(user, &1))
  end

  defp fresh_can_view?(scope), do: can_view?(scope)

  defp can_view?(scope), do: RBAC.can_any?(scope, @view_permissions)
  defp can_export?(scope), do: RBAC.can?(scope, @export_permission)

  defp ensure_recording_allowed(%RemoteAccessRecording{} = recording, scope) do
    if recording_view_allowed?(scope, recording), do: :ok, else: {:error, :not_found}
  end

  defp recording_view_allowed?(scope, %RemoteAccessRecording{} = recording) do
    RBAC.can?(scope, permission_for_recording(recording)) and
      (recording_requested_by_scope_user?(recording, scope) or RBAC.can?(scope, @view_all_permission))
  end

  defp permission_for_recording(%RemoteAccessRecording{} = recording) do
    case recording_protocol(recording) do
      "rdp" -> @rdp_view_permission
      _protocol -> @ssh_view_permission
    end
  end

  defp recording_protocol(%RemoteAccessRecording{manifest: manifest}) when is_map(manifest) do
    manifest["protocol"] || manifest[:protocol]
  end

  defp recording_protocol(_recording), do: "ssh"

  defp recording_requested_by_scope_user?(
         %RemoteAccessRecording{session: %RemoteAccessSession{requested_by: requested_by}},
         %Scope{user: %{id: user_id}}
       )
       when not is_nil(requested_by) and not is_nil(user_id) do
    requested_by == user_id
  end

  defp recording_requested_by_scope_user?(_recording, _scope), do: false

  defp desktop_recording?(%RemoteAccessRecording{} = recording) do
    recording_protocol(recording) in ["rdp", "desktop"]
  end

  defp selected?(%RemoteAccessRecording{id: id}, %RemoteAccessRecording{id: id}), do: true
  defp selected?(_selected, _recording), do: false

  defp target_label(%RemoteAccessRecording{} = recording) do
    manifest = recording.manifest || %{}
    host = manifest["target_host"] || recording.session_id
    port = manifest["target_port"]
    protocol = manifest["protocol"] || "remote"

    [protocol, host, port]
    |> Enum.reject(&blank?/1)
    |> Enum.join(":")
  end

  defp content_label(manifest) when is_map(manifest) do
    if manifest["raw_terminal_payloads_stored"] do
      "Terminal payloads stored by policy"
    else
      "Metadata-only"
    end
  end

  defp content_label(_manifest), do: "Metadata-only"

  defp desktop_policy_items(%RemoteAccessRecording{manifest: manifest}) when is_map(manifest) do
    policy = policy_value(manifest, "desktop_policy") || %{}
    tls = policy_value(policy, "tls") || %{}
    nla = policy_value(policy, "nla") || %{}
    screen = policy_value(policy, "screen") || %{}
    redirection = policy_value(policy, "redirection") || %{}
    approval = policy_value(policy, "approval") || %{}

    Enum.reject(
      [
        %{label: "Route", value: route_label(manifest)},
        %{label: "Credential", value: display_label(policy_value(manifest, "credential_custody_mode"))},
        %{label: "TLS/NLA", value: tls_nla_label(tls, nla)},
        %{label: "Screen quota", value: screen_quota_label(screen)},
        %{label: "Redirection", value: redirection_label(redirection)},
        %{label: "Approval", value: approval_label(manifest, approval)},
        %{label: "Recording", value: recording_policy_label(manifest)}
      ],
      &blank?(&1.value)
    )
  end

  defp desktop_policy_items(_recording), do: []

  defp route_label(manifest) do
    join_present([policy_value(manifest, "agent_id"), policy_value(manifest, "gateway_id")], " / ")
  end

  defp tls_nla_label(tls, nla) do
    join_present(
      [tls_mode_label(tls), nla_label(nla), policy_value(tls, "server_name") || policy_value(tls, "tls_server_name")],
      " · "
    )
  end

  defp tls_mode_label(tls) do
    mode =
      policy_value(tls, "mode") ||
        policy_value(tls, "certificate_trust_mode") ||
        policy_value(tls, "trust_mode")

    if blank?(mode), do: nil, else: "#{display_label(mode)} TLS"
  end

  defp nla_label(nla) do
    cond do
      truthy?(policy_value(nla, "required")) or truthy?(policy_value(nla, "enabled")) ->
        "NLA required"

      policy_value(nla, "required") in [false, "false", "no", "0", 0] ->
        "NLA not required"

      true ->
        nil
    end
  end

  defp screen_quota_label(screen) do
    resolution =
      case {policy_value(screen, "max_width"), policy_value(screen, "max_height")} do
        {width, height} when not is_nil(width) and not is_nil(height) -> "#{width}x#{height}"
        _other -> nil
      end

    join_present(
      [
        resolution,
        numeric_suffix(policy_value(screen, "max_frame_rate"), "fps"),
        numeric_suffix(policy_value(screen, "max_bitrate_kbps"), "kbps"),
        numeric_suffix(policy_value(screen, "color_depth"), "bit")
      ],
      " · "
    )
  end

  defp redirection_label(redirection) when is_map(redirection) do
    redirection
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.flat_map(fn {key, value} -> redirection_feature_label(key, value) end)
    |> Enum.take(4)
    |> join_present(" · ")
  end

  defp redirection_label(_redirection), do: nil

  defp redirection_feature_label(key, value) do
    feature = key |> to_string() |> String.replace("_", " ")

    cond do
      truthy?(value) -> ["#{String.capitalize(feature)} enabled"]
      value in [false, "false", "disabled", "deny", "none", "no", "0", 0] -> ["#{String.capitalize(feature)} disabled"]
      is_binary(value) and String.trim(value) != "" -> ["#{String.capitalize(feature)} #{display_label(value)}"]
      true -> []
    end
  end

  defp approval_label(manifest, approval) do
    join_present(
      [
        manifest |> policy_value("rbac_decision") |> display_label(),
        if(policy_value(manifest, "approval_id"), do: "Approval #{short_id(policy_value(manifest, "approval_id"))}"),
        if(truthy?(policy_value(approval, "required")), do: "Approval required")
      ],
      " · "
    )
  end

  defp recording_policy_label(manifest) do
    join_present([manifest |> policy_value("recording_mode") |> display_label(), content_label(manifest)], " · ")
  end

  defp policy_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, safe_existing_atom(key))
  end

  defp policy_value(_map, _key), do: nil

  defp safe_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp display_label(nil), do: nil

  defp display_label(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp numeric_suffix(nil, _suffix), do: nil
  defp numeric_suffix("", _suffix), do: nil
  defp numeric_suffix(value, suffix), do: "#{value} #{suffix}"

  defp join_present(values, separator) do
    values
    |> Enum.reject(&blank?/1)
    |> Enum.join(separator)
  end

  defp truthy?(value) when value in [true, "true", "required", "yes", "1", 1], do: true
  defp truthy?(_value), do: false

  defp short_id(nil), do: "-"
  defp short_id(id), do: id |> to_string() |> String.slice(0, 8)

  defp label(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp status_badge_variant(:completed), do: "success"
  defp status_badge_variant(:active), do: "info"
  defp status_badge_variant(:failed), do: "error"
  defp status_badge_variant(:expired), do: "warning"
  defp status_badge_variant(_status), do: "ghost"

  defp stream_badge_variant(:input), do: "warning"
  defp stream_badge_variant(:output), do: "info"
  defp stream_badge_variant(:enhanced_event), do: "info"
  defp stream_badge_variant(_stream), do: "ghost"

  defp redaction_label(nil), do: "Redacted"
  defp redaction_label(reason), do: reason |> to_string() |> String.replace("_", " ")

  defp format_error(%Ash.Error.Invalid{} = error), do: Exception.message(error)
  defp format_error(%Ash.Error.Forbidden{} = error), do: Exception.message(error)

  defp format_error(reason) when is_atom(reason), do: reason |> to_string() |> String.replace("_", " ")

  defp format_error(reason), do: inspect(reason)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(0), do: true
  defp blank?(_value), do: false
end
