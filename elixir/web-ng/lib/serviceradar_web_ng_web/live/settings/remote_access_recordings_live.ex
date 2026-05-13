defmodule ServiceRadarWebNGWeb.Settings.RemoteAccessRecordingsLive do
  @moduledoc """
  Operator replay page for remote-access session recordings.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadar.Edge.RemoteAccessRecording
  alias ServiceRadar.Edge.RemoteAccessRecordings
  alias ServiceRadarWebNG.RBAC

  require Ash.Query

  @current_path "/settings/networks/recordings"
  @view_permission "devices.remote_access.ssh.open"
  @export_permission "devices.remote_access.recordings.export"
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
    socket = assign(socket, :current_path, @current_path)

    if connected?(socket) do
      {:noreply, load_recordings(socket, params["id"])}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path={@current_path}>
        <div class="space-y-4">
          <.settings_nav current_path={@current_path} current_scope={@current_scope} />
          <.network_nav current_path={@current_path} current_scope={@current_scope} />
        </div>

        <section class="space-y-5">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h1 class="text-xl font-semibold">Remote Access Recordings</h1>
              <p class="mt-1 text-sm text-base-content/70">
                Review replay manifests and captured session events.
              </p>
            </div>
            <a
              :if={@selected_recording && @can_export?}
              class="btn btn-outline btn-sm"
              href={~p"/api/remote-access/recordings/#{@selected_recording.id}/export"}
              target="_blank"
              rel="noopener"
            >
              Export
            </a>
          </div>

          <div class="grid gap-4 lg:grid-cols-[minmax(20rem,24rem)_1fr]">
            <aside class="overflow-hidden rounded-lg border border-base-200 bg-base-100">
              <div class="border-b border-base-200 px-4 py-3">
                <h2 class="text-sm font-semibold">Recent Recordings</h2>
              </div>
              <div class="max-h-[42rem] overflow-y-auto">
                <div :if={@loading?} class="px-4 py-8 text-center text-sm text-base-content/60">
                  Loading recordings.
                </div>
                <div
                  :if={!@loading? and @recordings == []}
                  class="px-4 py-8 text-center text-sm text-base-content/60"
                >
                  No recordings found.
                </div>
                <.link
                  :for={recording <- @recordings}
                  navigate={~p"/settings/networks/recordings/#{recording.id}"}
                  class={[
                    "block border-b border-base-200 px-4 py-3 transition hover:bg-base-200/60",
                    selected?(@selected_recording, recording) && "bg-primary/10"
                  ]}
                >
                  <div class="flex items-center justify-between gap-3">
                    <span class="font-mono text-xs">{short_id(recording.session_id)}</span>
                    <span class={["badge badge-sm", status_badge_class(recording.status)]}>
                      {label(recording.status)}
                    </span>
                  </div>
                  <div class="mt-1 truncate text-sm font-medium">{target_label(recording)}</div>
                  <div class="mt-1 text-xs text-base-content/60">
                    {format_datetime(recording.started_at || recording.inserted_at)}
                  </div>
                </.link>
              </div>
            </aside>

            <div class="space-y-4">
              <div
                :if={!@selected_recording}
                class="rounded-lg border border-base-200 bg-base-100 p-8 text-center text-sm text-base-content/60"
              >
                Select a recording.
              </div>

              <.recording_summary :if={@selected_recording} recording={@selected_recording} />
              <.event_timeline :if={@selected_recording} events={@events} />
            </div>
          </div>
        </section>
      </.settings_shell>
    </Layouts.app>
    """
  end

  attr(:recording, :any, required: true)

  defp recording_summary(assigns) do
    ~H"""
    <section class="rounded-lg border border-base-200 bg-base-100 p-4">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h2 class="text-lg font-semibold">{target_label(@recording)}</h2>
          <p class="mt-1 font-mono text-xs text-base-content/60">Session {@recording.session_id}</p>
        </div>
        <span class={["badge", status_badge_class(@recording.status)]}>{label(@recording.status)}</span>
      </div>

      <dl class="mt-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <.summary_item label="Events" value={@recording.event_count} />
        <.summary_item label="Input bytes" value={@recording.input_bytes} />
        <.summary_item label="Output bytes" value={@recording.output_bytes} />
        <.summary_item label="Retention" value={format_datetime(@recording.retention_expires_at)} />
      </dl>

      <div class="mt-4 grid gap-3 lg:grid-cols-2">
        <div>
          <div class="text-xs font-semibold uppercase text-base-content/60">Storage</div>
          <div class="mt-1 break-all font-mono text-xs">
            {@recording.storage_backend}/{@recording.storage_bucket}/{@recording.object_key}
          </div>
        </div>
        <div>
          <div class="text-xs font-semibold uppercase text-base-content/60">Content</div>
          <div class="mt-1 text-sm">{content_label(@recording.manifest)}</div>
        </div>
      </div>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  defp summary_item(assigns) do
    ~H"""
    <div class="rounded-md border border-base-200 bg-base-200/40 p-3">
      <dt class="text-xs font-semibold uppercase text-base-content/60">{@label}</dt>
      <dd class="mt-1 break-words text-sm font-medium">{@value}</dd>
    </div>
    """
  end

  attr(:events, :list, required: true)

  defp event_timeline(assigns) do
    ~H"""
    <section class="overflow-hidden rounded-lg border border-base-200 bg-base-100">
      <div class="border-b border-base-200 px-4 py-3">
        <h2 class="text-sm font-semibold">Replay Events</h2>
      </div>
      <div :if={@events == []} class="px-4 py-8 text-center text-sm text-base-content/60">
        No replay events stored.
      </div>
      <div :for={event <- @events} class="border-b border-base-200 p-4 last:border-b-0">
        <div class="flex flex-wrap items-center gap-2">
          <span class="badge badge-sm">{event.sequence}</span>
          <span class={["badge badge-sm", stream_badge_class(event.stream)]}>{label(event.stream)}</span>
          <span class="text-sm font-medium">{event.event_type}</span>
          <span class="text-xs text-base-content/60">{format_datetime(event.occurred_at)}</span>
          <span :if={event.payload_redacted} class="badge badge-warning badge-sm">
            {redaction_label(event.redaction_reason)}
          </span>
        </div>
        <pre
          :if={event.payload_text}
          class="mt-3 max-h-72 overflow-auto rounded-md bg-base-200 p-3 text-xs whitespace-pre-wrap"
        ><%= event.payload_text %></pre>
        <div :if={!event.payload_text} class="mt-3 text-sm text-base-content/60">
          Payload text not stored. {event.byte_count} bytes, SHA-256 {event.payload_sha256 || "-"}.
        </div>
        <details :if={event.metadata != %{}} class="mt-3">
          <summary class="cursor-pointer text-xs font-semibold uppercase text-base-content/60">
            Metadata
          </summary>
          <pre class="mt-2 max-h-60 overflow-auto rounded-md bg-base-200 p-3 text-xs"><%= Jason.encode!(event.metadata, pretty: true) %></pre>
        </details>
      </div>
    </section>
    """
  end

  defp load_recordings(socket, selected_id) do
    case list_recent(socket.assigns.current_scope) do
      {:ok, recordings} ->
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
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(@list_limit)
    |> Ash.read(scope: scope)
  end

  defp get_recording(id, recordings, scope) do
    case Enum.find(recordings, &(&1.id == id)) do
      %RemoteAccessRecording{} = recording ->
        {:ok, recording}

      nil ->
        case RemoteAccessRecording.get_by_id(id, scope: scope) do
          {:ok, %RemoteAccessRecording{} = recording} -> {:ok, recording}
          {:ok, nil} -> {:error, :not_found}
          {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp normalize_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :invalid_id}
    end
  end

  defp can_view?(scope), do: RBAC.can?(scope, @view_permission)
  defp can_export?(scope), do: RBAC.can?(scope, @export_permission)

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

  defp short_id(nil), do: "-"
  defp short_id(id), do: id |> to_string() |> String.slice(0, 8)

  defp label(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp status_badge_class(:completed), do: "badge-success"
  defp status_badge_class(:active), do: "badge-info"
  defp status_badge_class(:failed), do: "badge-error"
  defp status_badge_class(:expired), do: "badge-warning"
  defp status_badge_class(_status), do: "badge-ghost"

  defp stream_badge_class(:input), do: "badge-warning"
  defp stream_badge_class(:output), do: "badge-info"
  defp stream_badge_class(:enhanced_event), do: "badge-secondary"
  defp stream_badge_class(_stream), do: "badge-ghost"

  defp redaction_label(nil), do: "Redacted"
  defp redaction_label(reason), do: reason |> to_string() |> String.replace("_", " ")

  defp format_datetime(nil), do: "-"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_datetime(value), do: inspect(value)

  defp format_error(%Ash.Error.Invalid{} = error), do: Exception.message(error)
  defp format_error(%Ash.Error.Forbidden{} = error), do: Exception.message(error)

  defp format_error(reason) when is_atom(reason),
    do: reason |> to_string() |> String.replace("_", " ")

  defp format_error(reason), do: inspect(reason)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(0), do: true
  defp blank?(_value), do: false
end
