defmodule ServiceRadarWebNGWeb.Settings.SoftwareLive.Index do
  @moduledoc """
  Software Library settings page.

  Sub-tabs: Library (images), Sessions (TFTP), Storage (config), Files (browser).
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadar.Software.SoftwareImage
  alias ServiceRadar.Software.TftpSession
  alias ServiceRadar.Software.StorageConfig
  alias ServiceRadar.Software.Storage
  alias ServiceRadar.Software.StorageToken
  alias ServiceRadar.Software.TftpPubSub
  alias ServiceRadar.AgentRegistry
  alias ServiceRadar.Infrastructure.Agent, as: InfraAgent
  alias ServiceRadarWebNG.RBAC

  require Ash.Query

  @max_upload_size 100 * 1024 * 1024

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    can_manage = RBAC.can?(scope, "settings.software.manage")
    can_view = RBAC.can?(scope, "settings.software.view") or can_manage

    if can_view do
      if connected?(socket) do
        TftpPubSub.subscribe()
        Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "agent:registrations")
      end

      {:ok,
       socket
       |> assign(:page_title, "Software Library")
       |> assign(:can_manage, can_manage)
       |> assign(:images, [])
       |> assign(:sessions, [])
       |> assign(:selected_image, nil)
       |> assign(:selected_session, nil)
       |> assign(:storage_config, nil)
       |> assign(:files, [])
       |> assign(:upload_errors, [])
       |> assign(:filter_status, nil)
       |> assign(:session_filter_status, nil)
       |> assign(:show_upload_form, false)
       |> assign(:show_session_form, false)
       |> assign(:session_mode, "receive")
       |> assign(:upload_form, default_upload_form())
       |> assign(:session_form, default_session_form())
       |> assign(:tftp_agents, [])
       |> assign(:tftp_agents_error, nil)
       |> assign(:file_search, "")
       |> assign(:file_date_filter, nil)
       |> assign(:storage_form, nil)
       |> assign(:editing_storage, false)
       |> assign(:editing_s3_creds, false)
       |> assign(:s3_test_result, nil)
       |> allow_upload(:image_file,
         accept: :any,
         max_entries: 1,
         max_file_size: @max_upload_size
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "You do not have access to Software settings")
       |> push_navigate(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :library, _params) do
    socket
    |> assign(:page_title, "Software Library")
    |> assign(:active_tab, :library)
    |> assign(:show_upload_form, false)
    |> assign(:selected_image, nil)
    |> load_images()
  end

  defp apply_action(socket, :upload, _params) do
    socket
    |> assign(:page_title, "Upload Image")
    |> assign(:active_tab, :library)
    |> assign(:show_upload_form, true)
    |> assign(:upload_form, default_upload_form())
    |> assign(:upload_errors, [])
    |> load_images()
  end

  defp apply_action(socket, :show_image, %{"id" => id}) do
    case load_image(id, socket.assigns.current_scope) do
      {:ok, image} ->
        socket
        |> assign(:page_title, "Image: #{image.name}")
        |> assign(:active_tab, :library)
        |> assign(:selected_image, image)

      _ ->
        socket
        |> put_flash(:error, "Image not found")
        |> push_navigate(to: ~p"/settings/software")
    end
  end

  defp apply_action(socket, :sessions, _params) do
    socket
    |> assign(:page_title, "TFTP Sessions")
    |> assign(:active_tab, :sessions)
    |> assign(:show_session_form, false)
    |> assign(:selected_session, nil)
    |> load_sessions()
  end

  defp apply_action(socket, :new_session, _params) do
    socket
    |> assign(:page_title, "New TFTP Session")
    |> assign(:active_tab, :sessions)
    |> assign(:show_session_form, true)
    |> assign(:session_form, default_session_form())
    |> load_sessions()
    |> load_images()
    |> load_tftp_agents()
  end

  defp apply_action(socket, :show_session, %{"id" => id}) do
    case load_session(id, socket.assigns.current_scope) do
      {:ok, session} ->
        socket
        |> assign(:page_title, "Session: #{session.expected_filename}")
        |> assign(:active_tab, :sessions)
        |> assign(:selected_session, session)

      _ ->
        socket
        |> put_flash(:error, "Session not found")
        |> push_navigate(to: ~p"/settings/software/sessions")
    end
  end

  defp apply_action(socket, :storage, _params) do
    socket
    |> assign(:page_title, "Storage Settings")
    |> assign(:active_tab, :storage)
    |> assign(:editing_storage, false)
    |> assign(:editing_s3_creds, false)
    |> assign(:s3_test_result, nil)
    |> load_storage_config()
    |> prepare_storage_form()
  end

  defp apply_action(socket, :files, _params) do
    socket
    |> assign(:page_title, "File Browser")
    |> assign(:active_tab, :files)
    |> load_files()
  end

  # -- Events --

  @impl true
  def handle_event("upload_change", _params, socket) do
    {:noreply, assign(socket, :upload_errors, [])}
  end

  def handle_event("update_upload_form", %{"upload" => params}, socket) do
    {:noreply, assign(socket, :upload_form, Map.merge(socket.assigns.upload_form, params))}
  end

  def handle_event("submit_upload", %{"upload" => params}, socket) do
    form = Map.merge(socket.assigns.upload_form, params)

    if socket.assigns.uploads.image_file.entries == [] do
      {:noreply,
       socket
       |> assign(:upload_errors, ["Please select a file to upload"])}
    else
      handle_image_upload(socket, form)
    end
  end

  def handle_event("verify_image", %{"id" => id}, socket) do
    with {:ok, image} <- load_image(id, socket.assigns.current_scope),
         {:ok, _} <- transition_image(image, :verify, socket.assigns.current_scope) do
      {:noreply,
       socket
       |> load_images()
       |> put_flash(:info, "Image verified")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to verify image")}
    end
  end

  def handle_event("activate_image", %{"id" => id}, socket) do
    with {:ok, image} <- load_image(id, socket.assigns.current_scope),
         {:ok, _} <- transition_image(image, :activate, socket.assigns.current_scope) do
      {:noreply,
       socket
       |> load_images()
       |> put_flash(:info, "Image activated")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to activate image")}
    end
  end

  def handle_event("archive_image", %{"id" => id}, socket) do
    with {:ok, image} <- load_image(id, socket.assigns.current_scope),
         {:ok, _} <- transition_image(image, :archive, socket.assigns.current_scope) do
      {:noreply,
       socket
       |> load_images()
       |> put_flash(:info, "Image archived")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to archive image")}
    end
  end

  def handle_event("delete_image", %{"id" => id}, socket) do
    with {:ok, image} <- load_image(id, socket.assigns.current_scope),
         {:ok, _} <- transition_image(image, :soft_delete, socket.assigns.current_scope) do
      {:noreply,
       socket
       |> load_images()
       |> put_flash(:info, "Image deleted")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to delete image")}
    end
  end

  def handle_event("filter_images", %{"status" => status}, socket) do
    {:noreply,
     socket
     |> assign(:filter_status, normalize_filter(status))
     |> load_images()}
  end

  def handle_event("update_session_form", %{"session" => params}, socket) do
    {:noreply, assign(socket, :session_form, Map.merge(socket.assigns.session_form, params))}
  end

  def handle_event("set_session_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :session_mode, mode)}
  end

  def handle_event("create_session", %{"session" => params}, socket) do
    mode = String.to_existing_atom(socket.assigns.session_mode)

    attrs = %{
      mode: mode,
      agent_id: params["agent_id"],
      expected_filename: params["expected_filename"],
      timeout_seconds: parse_int(params["timeout_seconds"], 300),
      notes: params["notes"],
      bind_address: params["bind_address"],
      port: parse_int(params["port"], 69),
      max_file_size: parse_int(params["max_file_size"], nil),
      image_id: if(mode == :serve, do: params["image_id"])
    }

    case create_tftp_session(attrs, socket.assigns.current_scope) do
      {:ok, _session} ->
        {:noreply,
         socket
         |> load_sessions()
         |> assign(:show_session_form, false)
         |> put_flash(:info, "TFTP session created and queued for dispatch")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed to create session: #{format_error(error)}")}
    end
  end

  def handle_event("cancel_session", %{"id" => id}, socket) do
    with {:ok, session} <- load_session(id, socket.assigns.current_scope),
         {:ok, _} <- cancel_session(session, socket.assigns.current_scope) do
      {:noreply,
       socket
       |> load_sessions()
       |> put_flash(:info, "Session canceled")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel session: #{format_error(reason)}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to cancel session")}
    end
  end

  def handle_event("delete_session", %{"id" => id}, socket) do
    with {:ok, session} <- load_session(id, socket.assigns.current_scope),
         {:ok, _} <- delete_session(session, socket.assigns.current_scope) do
      {:noreply,
       socket
       |> load_sessions()
       |> put_flash(:info, "Session deleted")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete session: #{format_error(reason)}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to delete session")}
    end
  end

  def handle_event("queue_session", %{"id" => id}, socket) do
    with {:ok, session} <- load_session(id, socket.assigns.current_scope),
         {:ok, _} <- queue_session(session, socket.assigns.current_scope) do
      {:noreply,
       socket
       |> load_sessions()
       |> put_flash(:info, "Session queued for dispatch")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to queue session: #{format_error(reason)}")}
    end
  end

  def handle_event("filter_sessions", %{"status" => status}, socket) do
    {:noreply,
     socket
     |> assign(:session_filter_status, normalize_filter(status))
     |> load_sessions()}
  end

  def handle_event("edit_storage", _params, socket) do
    {:noreply, assign(socket, :editing_storage, true)}
  end

  def handle_event("cancel_edit_storage", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_storage, false)
     |> prepare_storage_form()}
  end

  def handle_event("update_storage_form", %{"storage" => params}, socket) do
    {:noreply, assign(socket, :storage_form, Map.merge(socket.assigns.storage_form, params))}
  end

  def handle_event("save_storage", %{"storage" => params}, socket) do
    form = Map.merge(socket.assigns.storage_form, params)

    attrs = %{
      storage_mode: String.to_existing_atom(form["storage_mode"] || "local"),
      s3_bucket: form["s3_bucket"],
      s3_region: form["s3_region"],
      s3_endpoint: form["s3_endpoint"],
      s3_prefix: form["s3_prefix"],
      local_path: form["local_path"],
      retention_days: parse_int(form["retention_days"], 90)
    }

    result =
      case socket.assigns.storage_config do
        nil ->
          StorageConfig
          |> Ash.Changeset.for_create(:create, attrs)
          |> Ash.create()

        config ->
          config
          |> Ash.Changeset.for_update(:update, attrs)
          |> Ash.update()
      end

    case result do
      {:ok, _config} ->
        {:noreply,
         socket
         |> load_storage_config()
         |> prepare_storage_form()
         |> assign(:editing_storage, false)
         |> put_flash(:info, "Storage settings saved")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed to save: #{format_error(error)}")}
    end
  end

  def handle_event("edit_s3_creds", _params, socket) do
    {:noreply, assign(socket, :editing_s3_creds, true)}
  end

  def handle_event("cancel_s3_creds", _params, socket) do
    {:noreply, assign(socket, :editing_s3_creds, false)}
  end

  def handle_event("save_s3_creds", %{"creds" => params}, socket) do
    config = socket.assigns.storage_config

    if config do
      case config
           |> Ash.Changeset.for_update(:set_s3_credentials, %{
             s3_access_key_id: params["access_key_id"],
             s3_secret_access_key: params["secret_access_key"]
           })
           |> Ash.update() do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:editing_s3_creds, false)
           |> put_flash(:info, "S3 credentials saved")}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, "Failed to save credentials: #{format_error(error)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Save storage config first")}
    end
  end

  def handle_event("test_s3", _params, socket) do
    result = test_s3_connection()
    {:noreply, assign(socket, :s3_test_result, result)}
  end

  def handle_event("delete_file", %{"path" => path}, socket) do
    case Storage.delete(path) do
      :ok ->
        {:noreply,
         socket
         |> load_files()
         |> put_flash(:info, "File deleted")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  def handle_event("filter_files", params, socket) do
    {:noreply,
     socket
     |> assign(:file_search, params["search"] || "")
     |> assign(:file_date_filter, normalize_filter(params["date_range"]))
     |> load_files()}
  end

  # -- PubSub --

  @impl true
  def handle_info({:tftp_session_updated, data}, socket) do
    socket =
      if socket.assigns.active_tab == :sessions do
        socket
        |> update_session_in_list(data)
        |> maybe_update_selected_session(data)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:tftp_session_progress, data}, socket) do
    socket =
      if socket.assigns.active_tab == :sessions do
        update_session_progress_in_list(socket, data)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:agent_registered, _metadata}, socket) do
    {:noreply, load_tftp_agents(socket)}
  end

  def handle_info({:agent_disconnected, _agent_id}, socket) do
    {:noreply, load_tftp_agents(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp update_session_in_list(socket, data) do
    sessions =
      Enum.map(socket.assigns.sessions, fn session ->
        if session.id == data.id do
          %{session |
            status: data.status,
            bytes_transferred: data.bytes_transferred || session.bytes_transferred,
            transfer_rate: data.transfer_rate || session.transfer_rate,
            file_size: data.file_size || session.file_size
          }
        else
          session
        end
      end)

    assign(socket, :sessions, sessions)
  end

  defp maybe_update_selected_session(socket, data) do
    case socket.assigns.selected_session do
      %{id: id} when id == data.id ->
        selected = %{socket.assigns.selected_session |
          status: data.status,
          bytes_transferred: data.bytes_transferred || socket.assigns.selected_session.bytes_transferred,
          transfer_rate: data.transfer_rate || socket.assigns.selected_session.transfer_rate,
          file_size: data.file_size || socket.assigns.selected_session.file_size
        }
        assign(socket, :selected_session, selected)
      _ ->
        socket
    end
  end

  defp update_session_progress_in_list(socket, data) do
    sessions =
      Enum.map(socket.assigns.sessions, fn session ->
        if session.id == data.session_id do
          %{session |
            bytes_transferred: data[:bytes_transferred] || session.bytes_transferred,
            transfer_rate: data[:transfer_rate] || session.transfer_rate
          }
        else
          session
        end
      end)

    assign(socket, :sessions, sessions)
  end

  # -- Render --

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path="/settings/software">
        <.settings_nav current_path="/settings/software" current_scope={@current_scope} />
        <.software_nav current_path={current_software_path(@active_tab)} current_scope={@current_scope} />

        <div class="space-y-4">
          <%= case @active_tab do %>
            <% :library -> %>
              <.library_panel
                images={@images}
                selected_image={@selected_image}
                show_upload_form={@show_upload_form}
                upload_form={@upload_form}
                upload_errors={@upload_errors}
                uploads={@uploads}
                can_manage={@can_manage}
                live_action={@live_action}
                filter_status={@filter_status}
              />
            <% :sessions -> %>
              <.sessions_panel
                sessions={@sessions}
                selected_session={@selected_session}
                show_session_form={@show_session_form}
                session_form={@session_form}
                session_mode={@session_mode}
                images={@images}
                tftp_agents={@tftp_agents}
                tftp_agents_error={@tftp_agents_error}
                can_manage={@can_manage}
                live_action={@live_action}
                session_filter_status={@session_filter_status}
              />
            <% :storage -> %>
              <.storage_panel
                storage_config={@storage_config}
                storage_form={@storage_form}
                editing_storage={@editing_storage}
                editing_s3_creds={@editing_s3_creds}
                s3_test_result={@s3_test_result}
                can_manage={@can_manage}
              />
            <% :files -> %>
              <.files_panel
                files={@files}
                can_manage={@can_manage}
                file_search={@file_search}
                file_date_filter={@file_date_filter}
              />
          <% end %>
        </div>
      </.settings_shell>
    </Layouts.app>
    """
  end

  # -- Library Panel --

  defp library_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div>
          <div class="text-sm font-semibold">Software Images</div>
          <p class="text-xs text-base-content/60">
            {length(@images)} image(s)
          </p>
        </div>
        <div class="flex gap-2">
          <select name="status" class="select select-sm select-bordered" phx-change="filter_images">
            <option value="">All Statuses</option>
            <option value="uploaded" selected={@filter_status == "uploaded"}>Uploaded</option>
            <option value="verified" selected={@filter_status == "verified"}>Verified</option>
            <option value="active" selected={@filter_status == "active"}>Active</option>
            <option value="archived" selected={@filter_status == "archived"}>Archived</option>
          </select>
          <.link
            :if={@can_manage}
            navigate={~p"/settings/software/upload"}
            class="btn btn-primary btn-sm"
          >
            Upload Image
          </.link>
        </div>
      </:header>

      <%= if @live_action == :show_image and @selected_image do %>
        <.image_detail image={@selected_image} can_manage={@can_manage} />
      <% else %>
        <%= if @show_upload_form do %>
          <.upload_form
            form={@upload_form}
            errors={@upload_errors}
            uploads={@uploads}
          />
          <div class="divider my-2"></div>
        <% end %>

        <.image_table images={@images} can_manage={@can_manage} />
      <% end %>
    </.ui_panel>
    """
  end

  defp image_table(assigns) do
    ~H"""
    <%= if @images == [] do %>
      <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-8 text-center">
        <div class="text-sm font-semibold text-base-content">No images found</div>
        <p class="mt-1 text-xs text-base-content/60">
          Upload a firmware image or software package to get started.
        </p>
      </div>
    <% else %>
      <div class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr class="text-xs uppercase tracking-wide text-base-content/60">
              <th>Name</th>
              <th>Version</th>
              <th>Device Type</th>
              <th>Size</th>
              <th>Status</th>
              <th>Updated</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <%= for image <- @images do %>
              <tr class="hover:bg-base-200/30">
                <td>
                  <.link
                    navigate={~p"/settings/software/images/#{image.id}"}
                    class="font-medium hover:underline"
                  >
                    {image.name}
                  </.link>
                  <div class="text-xs text-base-content/60 font-mono truncate max-w-48">
                    {image.content_hash && String.slice(image.content_hash, 0..15) <> "..."}
                  </div>
                </td>
                <td class="text-xs">{image.version}</td>
                <td class="text-xs">{image.device_type || "-"}</td>
                <td class="text-xs">{format_bytes(image.file_size)}</td>
                <td><.image_status_badge status={image.status} /></td>
                <td class="text-xs text-base-content/70">
                  {format_datetime(image.updated_at)}
                </td>
                <td>
                  <div class="flex gap-1">
                    <.link
                      navigate={~p"/settings/software/images/#{image.id}"}
                      class="btn btn-ghost btn-xs"
                    >
                      View
                    </.link>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    <% end %>
    """
  end

  defp image_detail(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h3 class="text-lg font-semibold">{@image.name}</h3>
          <p class="text-sm text-base-content/60">Version {@image.version}</p>
        </div>
        <div class="flex gap-2">
          <.link navigate={~p"/settings/software"} class="btn btn-ghost btn-sm">
            Back to Library
          </.link>
        </div>
      </div>

      <div class="grid grid-cols-2 gap-4">
        <div class="rounded-lg border border-base-200 p-4 space-y-2">
          <div class="text-xs font-semibold uppercase text-base-content/60">Metadata</div>
          <div class="space-y-1 text-sm">
            <div><span class="text-base-content/60">Device Type:</span> {@image.device_type || "Any"}</div>
            <div><span class="text-base-content/60">Filename:</span> {@image.filename}</div>
            <div><span class="text-base-content/60">File Size:</span> {format_bytes(@image.file_size)}</div>
            <div><span class="text-base-content/60">Status:</span> <.image_status_badge status={@image.status} /></div>
          </div>
        </div>

        <div class="rounded-lg border border-base-200 p-4 space-y-2">
          <div class="text-xs font-semibold uppercase text-base-content/60">Integrity</div>
          <div class="space-y-1 text-sm">
            <div><span class="text-base-content/60">SHA-256:</span></div>
            <div class="font-mono text-xs break-all">{@image.content_hash || "Not computed"}</div>
            <div><span class="text-base-content/60">Object Key:</span> {@image.object_key || "Not stored"}</div>
            <div>
              <span class="text-base-content/60">Signature:</span>
              <%= if @image.signature && @image.signature != %{} do %>
                <.ui_badge variant="info" size="xs">{@image.signature["source"] || "signed"}</.ui_badge>
                <span :if={@image.signature["signer"]} class="text-xs ml-1">{@image.signature["signer"]}</span>
              <% else %>
                <span class="text-xs text-base-content/50">Unsigned</span>
              <% end %>
            </div>
          </div>
        </div>
      </div>

      <%= if @image.description do %>
        <div class="rounded-lg border border-base-200 p-4">
          <div class="text-xs font-semibold uppercase text-base-content/60 mb-1">Description</div>
          <p class="text-sm">{@image.description}</p>
        </div>
      <% end %>

      <div class="flex gap-2 pt-2">
        <.link
          :if={download_url(@image)}
          href={download_url(@image)}
          class="btn btn-sm btn-outline"
          target="_blank"
        >
          Download
        </.link>
        <button
          :if={@can_manage and @image.status == :uploaded}
          class="btn btn-sm btn-success"
          phx-click="verify_image"
          phx-value-id={@image.id}
        >
          Verify
        </button>
        <button
          :if={@can_manage and @image.status == :verified}
          class="btn btn-sm btn-primary"
          phx-click="activate_image"
          phx-value-id={@image.id}
        >
          Activate
        </button>
        <button
          :if={@can_manage and @image.status == :active}
          class="btn btn-sm btn-warning"
          phx-click="archive_image"
          phx-value-id={@image.id}
          data-confirm="Are you sure you want to archive this image?"
        >
          Archive
        </button>
        <button
          :if={@can_manage and @image.status in [:archived]}
          class="btn btn-sm btn-error"
          phx-click="delete_image"
          phx-value-id={@image.id}
          data-confirm="This will permanently delete the image. Are you sure?"
        >
          Delete
        </button>
      </div>
    </div>
    """
  end

  defp upload_form(assigns) do
    ~H"""
    <div class="space-y-4">
      <h3 class="text-sm font-semibold">Upload Software Image</h3>

      <.form
        for={%{}}
        phx-change="update_upload_form"
        phx-submit="submit_upload"
        class="space-y-3"
      >
        <div class="grid grid-cols-2 gap-3">
          <div>
            <label class="label"><span class="label-text text-xs">Name</span></label>
            <input
              type="text"
              name="upload[name]"
              value={@form["name"]}
              placeholder="e.g., cisco-ios-switch"
              class="input input-bordered input-sm w-full"
              required
            />
          </div>
          <div>
            <label class="label"><span class="label-text text-xs">Version</span></label>
            <input
              type="text"
              name="upload[version]"
              value={@form["version"]}
              placeholder="e.g., 15.2.7"
              class="input input-bordered input-sm w-full"
              required
            />
          </div>
        </div>

        <div class="grid grid-cols-2 gap-3">
          <div>
            <label class="label"><span class="label-text text-xs">Device Type</span></label>
            <input
              type="text"
              name="upload[device_type]"
              value={@form["device_type"]}
              placeholder="e.g., switch, router, ap"
              class="input input-bordered input-sm w-full"
            />
          </div>
          <div>
            <label class="label"><span class="label-text text-xs">Description</span></label>
            <input
              type="text"
              name="upload[description]"
              value={@form["description"]}
              placeholder="Optional description"
              class="input input-bordered input-sm w-full"
            />
          </div>
        </div>

        <div>
          <label class="label"><span class="label-text text-xs">Image File</span></label>
          <.live_file_input
            upload={@uploads.image_file}
            class="file-input file-input-bordered file-input-sm w-full"
          />
        </div>

        <%= for entry <- @uploads.image_file.entries do %>
          <div class="flex items-center gap-2 text-xs">
            <span class="font-medium">{entry.client_name}</span>
            <span class="text-base-content/50">
              ({format_bytes(entry.client_size)})
            </span>
            <%= for err <- upload_errors(@uploads.image_file, entry) do %>
              <span class="text-error">{upload_error_message(err)}</span>
            <% end %>
          </div>
        <% end %>

        <div class="collapse collapse-arrow border border-base-200 rounded-lg">
          <input type="checkbox" name="sig_toggle" />
          <div class="collapse-title text-xs font-semibold py-2 min-h-0">
            Signature Metadata (optional)
          </div>
          <div class="collapse-content px-4 pb-3">
            <div class="grid grid-cols-3 gap-3">
              <div>
                <label class="label"><span class="label-text text-xs">Signature Type</span></label>
                <select name="upload[sig_type]" class="select select-bordered select-sm w-full">
                  <option value="" selected={@form["sig_type"] == ""}>None</option>
                  <option value="gpg" selected={@form["sig_type"] == "gpg"}>GPG</option>
                  <option value="cosign" selected={@form["sig_type"] == "cosign"}>Cosign</option>
                  <option value="other" selected={@form["sig_type"] == "other"}>Other</option>
                </select>
              </div>
              <div>
                <label class="label"><span class="label-text text-xs">Key ID / Signer</span></label>
                <input
                  type="text"
                  name="upload[sig_signer]"
                  value={@form["sig_signer"]}
                  placeholder="e.g., vendor@example.com"
                  class="input input-bordered input-sm w-full"
                />
              </div>
              <div>
                <label class="label"><span class="label-text text-xs">Key ID</span></label>
                <input
                  type="text"
                  name="upload[sig_key_id]"
                  value={@form["sig_key_id"]}
                  placeholder="e.g., 0xABCD1234"
                  class="input input-bordered input-sm w-full"
                />
              </div>
            </div>
          </div>
        </div>

        <%= if @errors != [] do %>
          <div class="rounded-lg border border-error/40 bg-error/5 p-2 text-xs text-error">
            <%= for error <- @errors do %>
              <div>{error}</div>
            <% end %>
          </div>
        <% end %>

        <div class="flex gap-2 justify-end">
          <.link navigate={~p"/settings/software"} class="btn btn-ghost btn-sm">Cancel</.link>
          <button type="submit" class="btn btn-primary btn-sm">Upload</button>
        </div>
      </.form>
    </div>
    """
  end

  # -- Sessions Panel --

  defp sessions_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div>
          <div class="text-sm font-semibold">TFTP Sessions</div>
          <p class="text-xs text-base-content/60">
            {length(@sessions)} session(s)
          </p>
        </div>
        <div class="flex gap-2">
          <select name="status" class="select select-sm select-bordered" phx-change="filter_sessions">
            <option value="">All Statuses</option>
            <option value="active" selected={@session_filter_status == "active"}>Active</option>
            <option value="completed" selected={@session_filter_status == "completed"}>Completed</option>
            <option value="failed" selected={@session_filter_status == "failed"}>Failed</option>
          </select>
          <.link
            :if={@can_manage}
            navigate={~p"/settings/software/sessions/new"}
            class="btn btn-primary btn-sm"
          >
            New Session
          </.link>
        </div>
      </:header>

      <%= if @show_session_form do %>
        <.session_create_form
          form={@session_form}
          mode={@session_mode}
          images={@images}
          tftp_agents={@tftp_agents}
          tftp_agents_error={@tftp_agents_error}
        />
        <div class="divider my-2"></div>
      <% end %>

      <%= if @live_action == :show_session and @selected_session do %>
        <.session_detail session={@selected_session} can_manage={@can_manage} />
      <% else %>
        <.session_table sessions={@sessions} can_manage={@can_manage} />
      <% end %>
    </.ui_panel>
    """
  end

  defp session_table(assigns) do
    ~H"""
    <%= if @sessions == [] do %>
      <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-8 text-center">
        <div class="text-sm font-semibold text-base-content">No sessions found</div>
        <p class="mt-1 text-xs text-base-content/60">
          Create a TFTP session to transfer files with network devices.
        </p>
      </div>
    <% else %>
      <div class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr class="text-xs uppercase tracking-wide text-base-content/60">
              <th>Mode</th>
              <th>Agent</th>
              <th>Filename</th>
              <th>Status</th>
              <th>Progress</th>
              <th>Created</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <%= for session <- @sessions do %>
              <tr class="hover:bg-base-200/30">
                <td>
                  <.ui_badge variant={if(session.mode == :receive, do: "info", else: "warning")} size="xs">
                    {session.mode}
                  </.ui_badge>
                </td>
                <td class="text-xs font-mono">{session.agent_id}</td>
                <td class="text-xs">{session.expected_filename}</td>
                <td><.session_status_badge status={session.status} /></td>
                <td class="text-xs">
                  <.transfer_progress
                    bytes_transferred={session.bytes_transferred}
                    file_size={session.file_size || session.max_file_size}
                    transfer_rate={session.transfer_rate}
                    status={session.status}
                  />
                </td>
                <td class="text-xs text-base-content/70">
                  {format_datetime(session.inserted_at)}
                </td>
                <td>
                  <div class="flex gap-1">
                    <.link
                      navigate={~p"/settings/software/sessions/#{session.id}"}
                      class="btn btn-ghost btn-xs"
                    >
                      View
                    </.link>
                    <button
                      :if={@can_manage and session.status == :configuring}
                      class="btn btn-primary btn-xs"
                      phx-click="queue_session"
                      phx-value-id={session.id}
                    >
                      Queue
                    </button>
                    <button
                      :if={@can_manage and session.status in [:configuring, :queued, :waiting, :receiving, :staging, :ready, :serving]}
                      class="btn btn-ghost btn-xs text-error"
                      phx-click="cancel_session"
                      phx-value-id={session.id}
                      data-confirm="Cancel this TFTP session?"
                    >
                      Cancel
                    </button>
                    <button
                      :if={@can_manage}
                      class="btn btn-ghost btn-xs text-error"
                      phx-click="delete_session"
                      phx-value-id={session.id}
                      data-confirm="Delete this session record?"
                    >
                      Delete
                    </button>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    <% end %>
    """
  end

  defp session_detail(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h3 class="text-lg font-semibold">{@session.expected_filename}</h3>
          <p class="text-sm text-base-content/60">
            <.ui_badge variant={if(@session.mode == :receive, do: "info", else: "warning")} size="xs">
              {@session.mode}
            </.ui_badge>
            on agent <span class="font-mono">{@session.agent_id}</span>
          </p>
        </div>
        <div class="flex gap-2">
          <.link navigate={~p"/settings/software/sessions"} class="btn btn-ghost btn-sm">
            Back to Sessions
          </.link>
          <button
            :if={@can_manage and @session.status == :configuring}
            class="btn btn-primary btn-sm"
            phx-click="queue_session"
            phx-value-id={@session.id}
          >
            Queue for Dispatch
          </button>
          <button
            :if={@can_manage and @session.status in [:configuring, :queued, :waiting, :receiving, :staging, :ready, :serving]}
            class="btn btn-error btn-sm"
            phx-click="cancel_session"
            phx-value-id={@session.id}
            data-confirm="Cancel this TFTP session?"
          >
            Cancel
          </button>
          <button
            :if={@can_manage}
            class="btn btn-ghost btn-sm text-error"
            phx-click="delete_session"
            phx-value-id={@session.id}
            data-confirm="Delete this session record?"
          >
            Delete
          </button>
        </div>
      </div>

      <div class="grid grid-cols-2 gap-4">
        <div class="rounded-lg border border-base-200 p-4 space-y-2">
          <div class="text-xs font-semibold uppercase text-base-content/60">Configuration</div>
          <div class="space-y-1 text-sm">
            <div><span class="text-base-content/60">Status:</span> <.session_status_badge status={@session.status} /></div>
            <div><span class="text-base-content/60">Timeout:</span> {@session.timeout_seconds}s</div>
            <div><span class="text-base-content/60">Port:</span> {@session.port || 69}</div>
            <div :if={@session.bind_address}><span class="text-base-content/60">Bind:</span> {@session.bind_address}</div>
            <div :if={@session.max_file_size}><span class="text-base-content/60">Max Size:</span> {format_bytes(@session.max_file_size)}</div>
          </div>
        </div>

        <div class="rounded-lg border border-base-200 p-4 space-y-2">
          <div class="text-xs font-semibold uppercase text-base-content/60">Transfer</div>
          <.transfer_progress
            bytes_transferred={@session.bytes_transferred}
            file_size={@session.file_size || @session.max_file_size}
            transfer_rate={@session.transfer_rate}
            status={@session.status}
          />
          <div class="space-y-1 text-sm">
            <div><span class="text-base-content/60">Bytes:</span> {format_bytes(@session.bytes_transferred)}</div>
            <div :if={@session.transfer_rate}><span class="text-base-content/60">Rate:</span> {format_bytes(@session.transfer_rate)}/s</div>
            <div :if={@session.file_size}><span class="text-base-content/60">File Size:</span> {format_bytes(@session.file_size)}</div>
            <div :if={@session.content_hash}><span class="text-base-content/60">SHA-256:</span> <span class="font-mono text-xs">{@session.content_hash}</span></div>
          </div>
        </div>
      </div>

      <div :if={@session.error_message} class="rounded-lg border border-error/30 bg-error/5 p-4">
        <div class="text-xs font-semibold text-error">Error</div>
        <p class="text-sm mt-1">{@session.error_message}</p>
      </div>

      <div :if={@session.notes} class="rounded-lg border border-base-200 p-4">
        <div class="text-xs font-semibold uppercase text-base-content/60 mb-1">Notes</div>
        <p class="text-sm">{@session.notes}</p>
      </div>
    </div>
    """
  end

  defp session_create_form(assigns) do
    assigns = assign_new(assigns, :tftp_agents_error, fn -> nil end)

    ~H"""
    <div class="space-y-4">
      <h3 class="text-sm font-semibold">New TFTP Session</h3>

      <div class="flex gap-2 mb-3">
        <button
          type="button"
          class={"btn btn-sm #{if @mode == "receive", do: "btn-primary", else: "btn-ghost"}"}
          phx-click="set_session_mode"
          phx-value-mode="receive"
        >
          Receive (Device to Agent)
        </button>
        <button
          type="button"
          class={"btn btn-sm #{if @mode == "serve", do: "btn-primary", else: "btn-ghost"}"}
          phx-click="set_session_mode"
          phx-value-mode="serve"
        >
          Serve (Agent to Device)
        </button>
      </div>

      <.form
        for={%{}}
        phx-change="update_session_form"
        phx-submit="create_session"
        class="space-y-3"
      >
        <div class="grid grid-cols-2 gap-3">
          <div>
            <label class="label"><span class="label-text text-xs">Agent ID</span></label>
            <select name="session[agent_id]" class="select select-bordered select-sm w-full" required>
              <option value="">Select an agent...</option>
              <%= for agent <- @tftp_agents do %>
                <option value={agent.agent_id} selected={@form["agent_id"] == agent.agent_id}>
                  {agent.agent_id}<%= if agent.partition_id do %> ({agent.partition_id})<% end %>
                </option>
              <% end %>
            </select>
            <p :if={@tftp_agents == []} class="text-xs text-warning mt-1">
              No agents with TFTP capability found. Ensure agents are connected and advertising "tftp".
            </p>
            <p :if={@tftp_agents_error} class="text-xs text-error mt-1">
              {@tftp_agents_error}
            </p>
          </div>
          <div>
            <label class="label"><span class="label-text text-xs">Filename</span></label>
            <input
              type="text"
              name="session[expected_filename]"
              value={@form["expected_filename"]}
              placeholder={if @mode == "receive", do: "running-config", else: "firmware.bin"}
              class="input input-bordered input-sm w-full"
              required
            />
          </div>
        </div>

        <div class="grid grid-cols-3 gap-3">
          <div>
            <label class="label"><span class="label-text text-xs">Timeout (seconds)</span></label>
            <input
              type="number"
              name="session[timeout_seconds]"
              value={@form["timeout_seconds"] || "300"}
              class="input input-bordered input-sm w-full"
            />
          </div>
          <div>
            <label class="label"><span class="label-text text-xs">Port</span></label>
            <input
              type="number"
              name="session[port]"
              value={@form["port"] || "69"}
              class="input input-bordered input-sm w-full"
            />
          </div>
          <div>
            <label class="label"><span class="label-text text-xs">Max File Size (bytes)</span></label>
            <input
              type="number"
              name="session[max_file_size]"
              value={@form["max_file_size"]}
              placeholder="No limit"
              class="input input-bordered input-sm w-full"
            />
          </div>
        </div>

        <div :if={@mode == "serve"}>
          <label class="label"><span class="label-text text-xs">Software Image</span></label>
          <select name="session[image_id]" class="select select-bordered select-sm w-full" required>
            <option value="">Select an image...</option>
            <%= for image <- @images do %>
              <option value={image.id}>{image.name} v{image.version}</option>
            <% end %>
          </select>
        </div>

        <div>
          <label class="label"><span class="label-text text-xs">Notes</span></label>
          <textarea
            name="session[notes]"
            class="textarea textarea-bordered textarea-sm w-full"
            placeholder="Optional notes about this session"
            rows="2"
          >{@form["notes"]}</textarea>
        </div>

        <div class="flex gap-2 justify-end">
          <.link navigate={~p"/settings/software/sessions"} class="btn btn-ghost btn-sm">Cancel</.link>
          <button type="submit" class="btn btn-primary btn-sm">Create Session</button>
        </div>
      </.form>
    </div>
    """
  end

  # -- Storage Panel --

  defp storage_panel(assigns) do
    env_creds? = s3_env_configured?()
    assigns = assign(assigns, :env_creds?, env_creds?)

    ~H"""
    <.ui_panel>
      <:header>
        <div>
          <div class="text-sm font-semibold">Storage Configuration</div>
          <p class="text-xs text-base-content/60">
            Configure where software images and backups are stored.
          </p>
        </div>
        <button
          :if={@can_manage and not @editing_storage}
          class="btn btn-primary btn-sm"
          phx-click="edit_storage"
        >
          Edit
        </button>
      </:header>

      <div class="space-y-4">
        <%= if @editing_storage and @storage_form do %>
          <.storage_config_form form={@storage_form} />
        <% else %>
          <.storage_config_display config={@storage_config} />
        <% end %>

        <div class="rounded-lg border border-info/30 bg-info/5 p-4">
          <div class="text-xs font-semibold text-info">S3 Credentials</div>
          <%= if @env_creds? do %>
            <p class="text-sm mt-1 text-success">
              S3 credentials provided via environment variables. These take priority over database credentials.
            </p>
          <% else %>
            <p class="text-sm mt-1 text-base-content/70">
              No S3 credentials found in environment variables. You can store credentials encrypted in the database below.
            </p>
          <% end %>
        </div>

        <%= if @can_manage and not @env_creds? do %>
          <%= if @editing_s3_creds do %>
            <.s3_credentials_form />
          <% else %>
            <div class="flex gap-2">
              <button class="btn btn-sm btn-outline" phx-click="edit_s3_creds">
                Set S3 Credentials
              </button>
              <button class="btn btn-sm btn-outline" phx-click="test_s3">
                Test S3 Connection
              </button>
            </div>
          <% end %>
        <% end %>

        <%= if @can_manage and @env_creds? do %>
          <div class="flex gap-2">
            <button class="btn btn-sm btn-outline" phx-click="test_s3">
              Test S3 Connection
            </button>
          </div>
        <% end %>

        <%= if @s3_test_result do %>
          <div class={"rounded-lg border p-3 text-sm #{if @s3_test_result == :ok, do: "border-success/30 bg-success/5 text-success", else: "border-error/30 bg-error/5 text-error"}"}>
            <%= if @s3_test_result == :ok do %>
              S3 connection successful.
            <% else %>
              S3 connection failed: {@s3_test_result}
            <% end %>
          </div>
        <% end %>
      </div>
    </.ui_panel>
    """
  end

  defp storage_config_display(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-200 p-4 space-y-3">
      <div class="text-xs font-semibold uppercase text-base-content/60">Current Configuration</div>

      <%= if @config do %>
        <div class="space-y-1 text-sm">
          <div><span class="text-base-content/60">Mode:</span> <.ui_badge variant="info" size="xs">{@config.storage_mode}</.ui_badge></div>
          <div><span class="text-base-content/60">Local Path:</span> {@config.local_path || "/var/lib/serviceradar/software"}</div>
          <div><span class="text-base-content/60">Retention:</span> {@config.retention_days || 90} days</div>
          <div :if={@config.storage_mode in [:s3, :both]}>
            <span class="text-base-content/60">S3 Bucket:</span> {@config.s3_bucket || "Not configured"}
          </div>
          <div :if={@config.storage_mode in [:s3, :both]}>
            <span class="text-base-content/60">S3 Region:</span> {@config.s3_region || "us-east-1"}
          </div>
          <div :if={@config.storage_mode in [:s3, :both] and @config.s3_endpoint}>
            <span class="text-base-content/60">S3 Endpoint:</span> {@config.s3_endpoint}
          </div>
          <div :if={@config.storage_mode in [:s3, :both]}>
            <span class="text-base-content/60">S3 Prefix:</span> {@config.s3_prefix || "software/"}
          </div>
        </div>
      <% else %>
        <div class="text-sm text-base-content/60">
          Using default configuration (local storage at /var/lib/serviceradar/software).
        </div>
      <% end %>
    </div>
    """
  end

  defp storage_config_form(assigns) do
    ~H"""
    <.form
      for={%{}}
      phx-change="update_storage_form"
      phx-submit="save_storage"
      class="space-y-4"
    >
      <div class="rounded-lg border border-base-200 p-4 space-y-3">
        <div class="text-xs font-semibold uppercase text-base-content/60">General</div>

        <div>
          <label class="label"><span class="label-text text-xs">Storage Mode</span></label>
          <select name="storage[storage_mode]" class="select select-bordered select-sm w-full">
            <option value="local" selected={@form["storage_mode"] == "local"}>Local Only</option>
            <option value="s3" selected={@form["storage_mode"] == "s3"}>S3 Only</option>
            <option value="both" selected={@form["storage_mode"] == "both"}>Local + S3</option>
          </select>
        </div>

        <div>
          <label class="label"><span class="label-text text-xs">Local Storage Path</span></label>
          <input
            type="text"
            name="storage[local_path]"
            value={@form["local_path"]}
            class="input input-bordered input-sm w-full"
            placeholder="/var/lib/serviceradar/software"
          />
        </div>

        <div>
          <label class="label"><span class="label-text text-xs">Retention (days)</span></label>
          <input
            type="number"
            name="storage[retention_days]"
            value={@form["retention_days"]}
            class="input input-bordered input-sm w-full"
            min="1"
          />
        </div>
      </div>

      <div class="rounded-lg border border-base-200 p-4 space-y-3">
        <div class="text-xs font-semibold uppercase text-base-content/60">S3 Settings</div>

        <div class="grid grid-cols-2 gap-3">
          <div>
            <label class="label"><span class="label-text text-xs">Bucket</span></label>
            <input
              type="text"
              name="storage[s3_bucket]"
              value={@form["s3_bucket"]}
              class="input input-bordered input-sm w-full"
              placeholder="my-software-bucket"
            />
          </div>
          <div>
            <label class="label"><span class="label-text text-xs">Region</span></label>
            <input
              type="text"
              name="storage[s3_region]"
              value={@form["s3_region"]}
              class="input input-bordered input-sm w-full"
              placeholder="us-east-1"
            />
          </div>
        </div>

        <div class="grid grid-cols-2 gap-3">
          <div>
            <label class="label"><span class="label-text text-xs">Endpoint (optional)</span></label>
            <input
              type="text"
              name="storage[s3_endpoint]"
              value={@form["s3_endpoint"]}
              class="input input-bordered input-sm w-full"
              placeholder="https://s3.example.com"
            />
          </div>
          <div>
            <label class="label"><span class="label-text text-xs">Key Prefix</span></label>
            <input
              type="text"
              name="storage[s3_prefix]"
              value={@form["s3_prefix"]}
              class="input input-bordered input-sm w-full"
              placeholder="software/"
            />
          </div>
        </div>
      </div>

      <div class="flex gap-2 justify-end">
        <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel_edit_storage">Cancel</button>
        <button type="submit" class="btn btn-primary btn-sm">Save</button>
      </div>
    </.form>
    """
  end

  defp s3_credentials_form(assigns) do
    ~H"""
    <.form
      for={%{}}
      phx-submit="save_s3_creds"
      class="rounded-lg border border-warning/30 bg-warning/5 p-4 space-y-3"
    >
      <div class="text-xs font-semibold text-warning">Set S3 Credentials</div>
      <p class="text-xs text-base-content/60">
        Credentials will be encrypted with AES-256-GCM before storage.
      </p>

      <div class="grid grid-cols-2 gap-3">
        <div>
          <label class="label"><span class="label-text text-xs">Access Key ID</span></label>
          <input
            type="password"
            name="creds[access_key_id]"
            class="input input-bordered input-sm w-full"
            autocomplete="off"
            required
          />
        </div>
        <div>
          <label class="label"><span class="label-text text-xs">Secret Access Key</span></label>
          <input
            type="password"
            name="creds[secret_access_key]"
            class="input input-bordered input-sm w-full"
            autocomplete="off"
            required
          />
        </div>
      </div>

      <div class="flex gap-2 justify-end">
        <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel_s3_creds">Cancel</button>
        <button type="submit" class="btn btn-warning btn-sm">Save Credentials</button>
      </div>
    </.form>
    """
  end

  # -- Files Panel --

  defp files_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div>
          <div class="text-sm font-semibold">File Browser</div>
          <p class="text-xs text-base-content/60">
            {length(@files)} file(s) in storage
          </p>
        </div>
        <div class="flex gap-2 items-center">
          <input
            type="text"
            name="search"
            value={@file_search}
            placeholder="Filter by path..."
            class="input input-bordered input-sm w-48"
            phx-change="filter_files"
            phx-debounce="300"
          />
          <select name="date_range" class="select select-sm select-bordered" phx-change="filter_files">
            <option value="">Any Date</option>
            <option value="7" selected={@file_date_filter == "7"}>Last 7 days</option>
            <option value="30" selected={@file_date_filter == "30"}>Last 30 days</option>
            <option value="90" selected={@file_date_filter == "90"}>Last 90 days</option>
          </select>
        </div>
      </:header>

      <%= if @files == [] do %>
        <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-8 text-center">
          <div class="text-sm font-semibold text-base-content">No files in storage</div>
          <p class="mt-1 text-xs text-base-content/60">
            Files will appear here after images are uploaded or backups are received.
          </p>
        </div>
      <% else %>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr class="text-xs uppercase tracking-wide text-base-content/60">
                <th>Path</th>
                <th>Size</th>
                <th>Modified</th>
                <th></th>
                <th :if={@can_manage}></th>
              </tr>
            </thead>
            <tbody>
              <%= for file <- @files do %>
                <tr class="hover:bg-base-200/30">
                  <td class="text-xs font-mono">{file.path}</td>
                  <td class="text-xs">{format_bytes(file[:size])}</td>
                  <td class="text-xs text-base-content/70">{format_datetime(file[:modified])}</td>
                  <td>
                    <.link
                      :if={file_download_url(file)}
                      href={file_download_url(file)}
                      class="btn btn-ghost btn-xs"
                      target="_blank"
                    >
                      Download
                    </.link>
                  </td>
                  <td :if={@can_manage}>
                    <button
                      class="btn btn-ghost btn-xs text-error"
                      phx-click="delete_file"
                      phx-value-path={file.path}
                      data-confirm={"Delete #{file.path}? This cannot be undone."}
                    >
                      Delete
                    </button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </.ui_panel>
    """
  end

  # -- Status Badges --

  defp image_status_badge(assigns) do
    status = to_string(assigns.status)

    variant =
      case status do
        "uploaded" -> "ghost"
        "verified" -> "info"
        "active" -> "success"
        "archived" -> "warning"
        "deleted" -> "error"
        _ -> "ghost"
      end

    assigns = assigns |> assign(:variant, variant) |> assign(:label, status)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp session_status_badge(assigns) do
    status = to_string(assigns.status)

    variant =
      case status do
        "configuring" -> "ghost"
        "queued" -> "info"
        "waiting" -> "info"
        "receiving" -> "warning"
        "completed" -> "success"
        "storing" -> "warning"
        "stored" -> "success"
        "staging" -> "info"
        "ready" -> "info"
        "serving" -> "warning"
        "failed" -> "error"
        "expired" -> "ghost"
        "canceled" -> "ghost"
        _ -> "ghost"
      end

    assigns = assigns |> assign(:variant, variant) |> assign(:label, status)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  # -- Transfer Progress --

  defp transfer_progress(assigns) do
    active? = assigns.status in [:receiving, :serving, :storing, :staging]
    bytes = assigns.bytes_transferred || 0
    total = assigns.file_size
    rate = assigns.transfer_rate

    pct =
      if total && total > 0 && bytes > 0,
        do: min(round(bytes / total * 100), 100),
        else: nil

    eta =
      if rate && rate > 0 && total && total > bytes,
        do: round((total - bytes) / rate),
        else: nil

    assigns =
      assigns
      |> assign(:active?, active?)
      |> assign(:bytes, bytes)
      |> assign(:pct, pct)
      |> assign(:eta, eta)
      |> assign(:rate, rate)

    ~H"""
    <%= if @active? and @bytes > 0 do %>
      <div class="space-y-0.5 min-w-24">
        <div :if={@pct} class="flex items-center gap-1">
          <progress class="progress progress-primary w-16 h-1.5" value={@pct} max="100"></progress>
          <span class="text-[10px] text-base-content/60">{@pct}%</span>
        </div>
        <div class="text-[10px] text-base-content/60">
          {format_bytes(@bytes)}
          <span :if={@rate}> &middot; {format_bytes(@rate)}/s</span>
          <span :if={@eta}> &middot; {format_eta(@eta)}</span>
        </div>
      </div>
    <% else %>
      <%= if @bytes > 0 do %>
        {format_bytes(@bytes)}
      <% else %>
        -
      <% end %>
    <% end %>
    """
  end

  defp format_eta(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_eta(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  defp format_eta(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  # -- Data Loading --

  defp load_images(socket) do
    images =
      try do
        query =
          SoftwareImage
          |> Ash.Query.for_read(:list, %{})
          |> Ash.Query.sort(inserted_at: :desc)

        query =
          case socket.assigns[:filter_status] do
            nil -> query
            status -> Ash.Query.filter(query, status == ^String.to_existing_atom(status))
          end

        case Ash.read(query, scope: socket.assigns.current_scope) do
          {:ok, %{results: results}} -> results
          {:ok, results} when is_list(results) -> results
          _ -> []
        end
      rescue
        _ -> []
      end

    assign(socket, :images, images)
  end

  defp load_image(id, scope) do
    SoftwareImage
    |> Ash.Query.for_read(:by_id, %{id: id})
    |> Ash.read_one(scope: scope)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, image} -> {:ok, image}
      error -> error
    end
  end

  defp load_sessions(socket) do
    sessions =
      try do
        query =
          TftpSession
          |> Ash.Query.for_read(:list, %{})
          |> Ash.Query.sort(inserted_at: :desc)

        query =
          case socket.assigns[:session_filter_status] do
            "active" ->
              Ash.Query.filter(query,
                status in [
                  :configuring,
                  :queued,
                  :waiting,
                  :receiving,
                  :staging,
                  :ready,
                  :serving,
                  :storing
                ]
              )

            "completed" ->
              Ash.Query.filter(query, status in [:completed, :stored])

            "failed" ->
              Ash.Query.filter(query, status in [:failed, :expired, :canceled])

            _ ->
              query
          end

        case Ash.read(query, scope: socket.assigns.current_scope) do
          {:ok, %{results: results}} -> results
          {:ok, results} when is_list(results) -> results
          _ -> []
        end
      rescue
        _ -> []
      end

    assign(socket, :sessions, sessions)
  end

  defp load_session(id, scope) do
    TftpSession
    |> Ash.Query.for_read(:by_id, %{id: id})
    |> Ash.read_one(scope: scope)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, session} -> {:ok, session}
      error -> error
    end
  end

  defp load_storage_config(socket) do
    config =
      try do
        case Ash.read_one(StorageConfig, action: :get_config, scope: socket.assigns.current_scope) do
          {:ok, config} -> config
          _ -> nil
        end
      rescue
        _ -> nil
      end

    assign(socket, :storage_config, config)
  end

  defp load_files(socket) do
    files =
      case Storage.list_with_metadata() do
        {:ok, files} -> files
        _ -> []
      end

    files = filter_files(files, socket.assigns[:file_search], socket.assigns[:file_date_filter])
    assign(socket, :files, files)
  end

  # -- Mutations --

  defp handle_image_upload(socket, form) do
    results =
      consume_uploaded_entries(socket, :image_file, fn %{path: path}, entry ->
        {:ok, {path, entry.client_name, entry.client_size}}
      end)

    case results do
      [{temp_path, client_name, client_size}] ->
        attrs = %{
          name: form["name"],
          version: form["version"],
          device_type: form["device_type"],
          description: form["description"],
          filename: client_name,
          file_size: client_size
        }

        # Build signature metadata if provided
        attrs = maybe_add_signature(attrs, form)

        # Compute hash
        hash_result = Storage.sha256(temp_path)
        attrs = case hash_result do
          {:ok, hash} -> Map.put(attrs, :content_hash, hash)
          _ -> attrs
        end

        # Store the file
        object_key = "images/#{form["name"]}/#{form["version"]}/#{client_name}"

        case Storage.put(object_key, temp_path) do
          {:ok, _} ->
            attrs = Map.put(attrs, :object_key, object_key)

            case create_image(attrs, socket.assigns.current_scope) do
              {:ok, _image} ->
                {:noreply,
                 socket
                 |> load_images()
                 |> assign(:show_upload_form, false)
                 |> assign(:upload_errors, [])
                 |> put_flash(:info, "Image uploaded successfully")
                 |> push_navigate(to: ~p"/settings/software")}

              {:error, error} ->
                {:noreply,
                 socket
                 |> assign(:upload_errors, [format_error(error)])
                 |> put_flash(:error, "Failed to create image record")}
            end

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:upload_errors, ["Storage error: #{inspect(reason)}"])
             |> put_flash(:error, "Failed to store file")}
        end

      _ ->
        {:noreply,
         socket
         |> assign(:upload_errors, ["Failed to process uploaded file"])}
    end
  end

  defp create_image(attrs, scope) do
    SoftwareImage
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create(scope: scope)
  end

  defp transition_image(image, action, scope) do
    image
    |> Ash.Changeset.for_update(action, %{}, scope: scope)
    |> Ash.update(scope: scope)
  end

  defp create_tftp_session(attrs, scope) do
    TftpSession
    |> Ash.Changeset.for_create(:create_and_queue, attrs, scope: scope)
    |> Ash.create(scope: scope)
  end

  defp cancel_session(session, scope) do
    session
    |> Ash.Changeset.for_update(:cancel, %{}, scope: scope)
    |> Ash.update(scope: scope)
  end

  defp delete_session(session, scope) do
    Ash.destroy(session, scope: scope)
  end

  defp queue_session(session, scope) do
    session
    |> Ash.Changeset.for_update(:queue, %{}, scope: scope)
    |> Ash.update(scope: scope)
  end

  defp load_tftp_agents(socket) do
    {live_agents, live_error} = load_live_tftp_agents()
    db_agents = load_db_tftp_agents(socket)

    merged_agents =
      (live_agents ++ db_agents)
      |> Enum.reduce(%{}, fn agent, acc -> Map.put(acc, agent.agent_id, agent) end)
      |> Map.values()
      |> Enum.sort_by(& &1.agent_id)

    socket
    |> assign(:tftp_agents, merged_agents)
    |> assign(:tftp_agents_error, live_error)
  end

  defp load_live_tftp_agents do
    try do
      agents =
        AgentRegistry.find_agents_with_capability(:tftp)
        |> Enum.map(fn agent ->
          %{
            agent_id: Map.get(agent, :agent_id) || Map.get(agent, :key),
            partition_id: Map.get(agent, :partition_id),
            status: Map.get(agent, :status, :unknown)
          }
        end)

      {agents, nil}
    rescue
      error ->
        {[],
         "Live agent registry unavailable (#{Exception.message(error)}). Showing database fallback."}
    end
  end

  defp load_db_tftp_agents(socket) do
    scope = socket.assigns.current_scope

    InfraAgent
    |> Ash.Query.for_read(:by_capability, %{capability: "tftp"})
    |> Ash.read(scope: scope)
    |> case do
      {:ok, page_or_agents} ->
        page_or_agents
        |> extract_results()
        |> Enum.map(fn agent ->
          %{
            agent_id: agent.uid,
            partition_id: get_in(agent.metadata || %{}, ["partition_id"]),
            status: if(agent.is_healthy, do: :connected, else: :unknown)
          }
        end)

      _ ->
        []
    end
  end

  defp extract_results(%Ash.Page.Keyset{} = page), do: page.results
  defp extract_results(results) when is_list(results), do: results
  defp extract_results(_), do: []

  defp filter_files(files, search, date_filter) do
    files
    |> filter_by_search(search)
    |> filter_by_date(date_filter)
  end

  defp filter_by_search(files, nil), do: files
  defp filter_by_search(files, ""), do: files

  defp filter_by_search(files, search) do
    term = String.downcase(search)

    Enum.filter(files, fn file ->
      file.path |> to_string() |> String.downcase() |> String.contains?(term)
    end)
  end

  defp filter_by_date(files, nil), do: files

  defp filter_by_date(files, days_str) do
    case Integer.parse(days_str) do
      {days, _} ->
        cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

        Enum.filter(files, fn file ->
          case file[:modified] do
            %DateTime{} = dt -> DateTime.compare(dt, cutoff) != :lt
            _ -> true
          end
        end)

      _ ->
        files
    end
  end

  # -- Helpers --

  defp maybe_add_signature(attrs, form) do
    sig_type = form["sig_type"]

    if sig_type in ["gpg", "cosign", "other"] do
      signature =
        %{"source" => sig_type, "verified" => false, "hash_algorithm" => "sha256"}
        |> maybe_put("signer", form["sig_signer"])
        |> maybe_put("key_id", form["sig_key_id"])

      Map.put(attrs, :signature, signature)
    else
      attrs
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp prepare_storage_form(socket) do
    config = socket.assigns.storage_config

    form =
      if config do
        %{
          "storage_mode" => to_string(config.storage_mode),
          "s3_bucket" => config.s3_bucket || "",
          "s3_region" => config.s3_region || "",
          "s3_endpoint" => config.s3_endpoint || "",
          "s3_prefix" => config.s3_prefix || "software/",
          "local_path" => config.local_path || "/var/lib/serviceradar/software",
          "retention_days" => to_string(config.retention_days || 90)
        }
      else
        %{
          "storage_mode" => "local",
          "s3_bucket" => "",
          "s3_region" => "",
          "s3_endpoint" => "",
          "s3_prefix" => "software/",
          "local_path" => "/var/lib/serviceradar/software",
          "retention_days" => "90"
        }
      end

    assign(socket, :storage_form, form)
  end

  defp s3_env_configured? do
    access_key = System.get_env("S3_ACCESS_KEY_ID")
    secret_key = System.get_env("S3_SECRET_ACCESS_KEY")
    is_binary(access_key) and access_key != "" and
      is_binary(secret_key) and secret_key != ""
  end

  defp test_s3_connection do
    case Storage.list("__test__/") do
      {:ok, _} -> :ok
      {:error, reason} -> inspect(reason)
    end
  rescue
    e -> Exception.message(e)
  end

  defp default_upload_form do
    %{
      "name" => "",
      "version" => "",
      "device_type" => "",
      "description" => "",
      "sig_type" => "",
      "sig_signer" => "",
      "sig_key_id" => ""
    }
  end

  defp default_session_form do
    %{
      "agent_id" => "",
      "expected_filename" => "",
      "timeout_seconds" => "300",
      "port" => "69",
      "max_file_size" => "",
      "notes" => "",
      "bind_address" => "",
      "image_id" => ""
    }
  end

  defp current_software_path(:library), do: "/settings/software"
  defp current_software_path(:sessions), do: "/settings/software/sessions"
  defp current_software_path(:storage), do: "/settings/software/storage"
  defp current_software_path(:files), do: "/settings/software/files"

  defp format_bytes(nil), do: "-"
  defp format_bytes(0), do: "0 B"

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "-"

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_datetime(_), do: "-"

  defp format_error(error) when is_binary(error), do: error
  defp format_error(%Ash.Error.Invalid{} = error), do: Exception.message(error)
  defp format_error(error), do: inspect(error)

  defp normalize_filter(nil), do: nil
  defp normalize_filter(""), do: nil
  defp normalize_filter(value), do: value

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_, default), do: default

  defp download_url(%{id: id, object_key: key}) when is_binary(key) and key != "" do
    StorageToken.download_url(id, key)
  end

  defp download_url(_), do: nil

  defp file_download_url(%{path: path}) when is_binary(path) and path != "" do
    StorageToken.download_url(path, path)
  end

  defp file_download_url(_), do: nil

  defp upload_error_message(:too_large), do: "File is too large (max 100 MB)"
  defp upload_error_message(:too_many_files), do: "Only one file allowed"
  defp upload_error_message(err), do: inspect(err)
end
