defmodule ServiceRadarWebNGWeb.DeviceLive.IndexEvents.DeviceManagement do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias Ash.Error.Forbidden
  alias Ash.Error.Invalid
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.DeviceLive.IndexCsvImport

  require Logger

  def handle_event("open_add_device_modal", _params, socket) do
    if RBAC.can?(socket.assigns.current_scope, "devices.create") do
      {:noreply, assign(socket, :show_add_device_modal, true)}
    else
      {:noreply, put_flash(socket, :error, "You are not authorized to add devices")}
    end
  end

  def handle_event("close_add_device_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_device_modal, false)
     |> assign(:add_device_form, to_form(%{}, as: :device))}
  end

  def handle_event("open_import_modal", _params, socket) do
    if RBAC.can?(socket.assigns.current_scope, "devices.import") do
      {:noreply,
       socket
       |> assign(:show_import_modal, true)
       |> assign(:csv_preview, nil)
       |> assign(:csv_errors, [])
       |> assign(:csv_warnings, [])
       |> assign(:import_status, nil)}
    else
      {:noreply, put_flash(socket, :error, "You are not authorized to import devices")}
    end
  end

  def handle_event("close_import_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_import_modal, false)
     |> assign(:csv_preview, nil)
     |> assign(:csv_errors, [])
     |> assign(:csv_warnings, [])
     |> assign(:import_status, nil)}
  end

  def handle_event("validate_csv", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("preview_csv", _params, socket) do
    if RBAC.can?(socket.assigns.current_scope, "devices.import") do
      preview_csv_upload(socket)
    else
      {:noreply, put_flash(socket, :error, "You are not authorized to import devices")}
    end
  end

  def handle_event("import_csv", _params, socket) do
    if RBAC.can?(socket.assigns.current_scope, "devices.import") do
      import_csv_preview(socket)
    else
      {:noreply, put_flash(socket, :error, "You are not authorized to import devices")}
    end
  end

  def handle_event("validate_device", %{"device" => params}, socket) do
    {:noreply, assign(socket, :add_device_form, to_form(params, as: :device))}
  end

  def handle_event("save_device", %{"device" => params}, socket) do
    if RBAC.can?(socket.assigns.current_scope, "devices.create") do
      save_device(socket, params)
    else
      {:noreply, put_flash(socket, :error, "You are not authorized to add devices")}
    end
  end

  defp save_device(socket, params) do
    scope = socket.assigns.current_scope

    case IndexCsvImport.create_device(scope, params) do
      {:ok, device} ->
        {:noreply,
         socket
         |> assign(:show_add_device_modal, false)
         |> assign(:add_device_form, to_form(%{}, as: :device))
         |> put_flash(:info, "Device '#{device.hostname || device.ip}' saved successfully.")
         |> push_navigate(to: ~p"/devices/#{device.uid}")}

      {:error, %Invalid{} = error} ->
        Logger.warning("Device create failed with validation error: #{inspect(error)}")
        {:noreply, put_flash(socket, :error, IndexCsvImport.format_device_error(error))}

      {:error, %Forbidden{}} ->
        {:noreply, put_flash(socket, :error, "You are not authorized to add devices")}

      {:error, :already_exists} ->
        {:noreply, put_flash(socket, :error, "A device with this IP address already exists.")}

      {:error, {:hostname_resolution_failed, hostname, reason}} ->
        Logger.warning("Device create failed: unable to resolve hostname #{inspect(hostname)}: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Unable to resolve hostname '#{hostname}' to an IP address.")}

      {:error, :missing_device_address} ->
        {:noreply, put_flash(socket, :error, "Provide a hostname that resolves or an IP address.")}

      {:error, :missing_scope} ->
        Logger.error("Device create failed: missing scope for #{inspect(params)}")
        {:noreply, put_flash(socket, :error, "Failed to create device: missing user scope")}

      {:error, reason} ->
        Logger.error("Device create failed: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to create device")}
    end
  end

  defp preview_csv_upload(socket) do
    case uploaded_entries(socket, :csv_file) do
      [] ->
        {:noreply, assign(socket, :csv_errors, ["No file selected"])}

      [entry | _] ->
        result =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            IndexCsvImport.parse_csv_file(path)
          end)

        case result do
          # Parse warnings are kept apart from import errors: the preview still
          # shows the rows that parsed, so a partly-bad file is visibly partial,
          # but a later creation failure must not inherit the warning styling.
          {:ok, devices, warnings} ->
            {:noreply,
             socket
             |> assign(:csv_preview, devices)
             |> assign(:csv_warnings, warnings)
             |> assign(:csv_errors, [])
             |> assign(:import_status, nil)}

          {:error, errors} ->
            {:noreply,
             socket
             |> assign(:csv_preview, nil)
             |> assign(:csv_warnings, [])
             |> assign(:csv_errors, errors)
             |> assign(:import_status, nil)}
        end
    end
  end

  defp import_csv_preview(socket) do
    case socket.assigns.csv_preview do
      nil ->
        {:noreply, assign(socket, :csv_errors, ["No CSV data to import. Preview first."])}

      devices when is_list(devices) and devices != [] ->
        scope = socket.assigns.current_scope

        case IndexCsvImport.import_devices(scope, devices) do
          {:ok, {created, skipped}} ->
            {:noreply,
             socket
             |> assign(:show_import_modal, false)
             |> assign(:csv_preview, nil)
             |> assign(:csv_warnings, [])
             |> assign(:csv_errors, [])
             |> assign(:import_status, nil)
             |> put_flash(:info, IndexCsvImport.import_success_message(created, skipped))
             |> push_patch(to: ~p"/devices")}

          {:error, %{created: created, skipped: skipped, errors: errors}} ->
            {:noreply,
             socket
             |> assign(:csv_preview, nil)
             |> assign(:csv_errors, errors)
             |> assign(
               :import_status,
               IndexCsvImport.import_partial_message(created, skipped, length(errors))
             )}
        end

      _ ->
        {:noreply, assign(socket, :csv_errors, ["No valid devices in CSV"])}
    end
  end
end
