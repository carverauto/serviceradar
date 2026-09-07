defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceActionRuntime do
  @moduledoc false

  use ServiceRadarWebNGWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [clear_flash: 2, put_flash: 3, push_patch: 2]

  alias Ash.Error.Invalid
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.DeviceLive.CameraRelayRuntime
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceFormData
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceResourceData
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceStateData
  alias ServiceRadarWebNGWeb.DeviceLive.IpAliasData
  alias ServiceRadarWebNGWeb.DeviceLive.SNMPCredentialData

  require Logger

  def toggle_edit(socket) do
    if socket.assigns.editing do
      socket
      |> assign(:editing, false)
      |> assign(:device_form, to_form(%{}, as: :device))
      |> assign(:snmp_credential_form, to_form(%{}, as: :snmp))
    else
      device_row = List.first(Enum.filter(socket.assigns.results, &is_map/1))
      scope = socket.assigns.current_scope

      device_snmp_credential =
        socket.assigns.device_snmp_credential ||
          SNMPCredentialData.load(scope, socket.assigns.device_uid)

      form_data = device_form_data(device_row)

      socket
      |> assign(:editing, true)
      |> assign(:device_snmp_credential, device_snmp_credential)
      |> assign(:device_form, to_form(form_data, as: :device))
      |> assign(
        :snmp_credential_form,
        to_form(SNMPCredentialData.form_data(device_snmp_credential), as: :snmp)
      )
    end
  end

  def delete_device(socket) do
    scope = socket.assigns.current_scope
    device_uid = socket.assigns.device_uid
    deleted_by = DeviceStateData.deleted_by_from_scope(scope)

    case DeviceResourceData.soft_delete(scope, device_uid, deleted_by) do
      {:ok, _} ->
        socket
        |> put_flash(:info, "Device deleted")
        |> push_patch(to: device_show_path(socket, device_uid))

      {:error, reason} ->
        Logger.error("Device delete failed for #{device_uid}: #{inspect(reason)}")

        put_flash(socket, :error, "Failed to delete device: #{format_ash_error(reason)}")
    end
  end

  def restore_device(socket) do
    scope = socket.assigns.current_scope
    device_uid = socket.assigns.device_uid

    case DeviceResourceData.restore(scope, device_uid) do
      :ok ->
        socket
        |> put_flash(:info, "Device restored")
        |> push_patch(to: device_show_path(socket, device_uid))

      {:error, reason} ->
        Logger.error("Device restore failed for #{device_uid}: #{inspect(reason)}")

        put_flash(socket, :error, "Failed to restore device: #{format_ash_error(reason)}")
    end
  end

  def mark_active(socket, active?) do
    scope = socket.assigns.current_scope
    device_uid = socket.assigns.device_uid

    case DeviceResourceData.set_active(scope, device_uid, active?) do
      {:ok, _updated} ->
        message = if active?, do: "Device returned to service", else: "Device marked out of service"

        socket
        |> put_flash(:info, message)
        |> push_patch(to: device_show_path(socket, device_uid))

      {:error, reason} ->
        action = if active?, do: "return device to service", else: "mark device out of service"

        Logger.error("Device active lifecycle update failed for #{device_uid}: #{inspect(reason)}")

        put_flash(socket, :error, "Failed to #{action}: #{format_ash_error(reason)}")
    end
  end

  def toggle_aliases(socket) do
    show_stale = not socket.assigns.show_stale_aliases
    scope = socket.assigns.current_scope
    device_uid = socket.assigns.device_uid

    {ip_aliases, ip_alias_error} = IpAliasData.load(scope, device_uid, show_stale)

    socket
    |> assign(:show_stale_aliases, show_stale)
    |> assign(:ip_aliases, ip_aliases)
    |> assign(:ip_alias_error, ip_alias_error)
  end

  def set_availability_source(socket, agent_id) do
    scope = socket.assigns.current_scope
    device_uid = socket.assigns.device_uid
    availability_source_agent_id = normalize_agent_id(agent_id)

    case DeviceResourceData.load(scope, device_uid) do
      {:ok, device} ->
        result =
          device
          |> Ash.Changeset.for_update(:set_availability_source, %{
            availability_source_agent_id: availability_source_agent_id,
            availability_source_profile_id: nil
          })
          |> Ash.update(scope: scope)

        case result do
          {:ok, _updated} ->
            socket
            |> put_flash(:info, "Availability source updated")
            |> push_patch(to: device_show_path(socket, device_uid))

          {:error, reason} ->
            put_flash(
              socket,
              :error,
              "Failed to update availability source: #{format_ash_error(reason)}"
            )
        end

      {:error, reason} ->
        put_flash(socket, :error, "Failed to load device: #{format_ash_error(reason)}")
    end
  end

  def open_camera_relay(socket, camera_source_id, stream_profile_id, params) do
    scope = socket.assigns.current_scope
    insecure_skip_verify = DeviceFormData.parse_bool(params["insecure_skip_verify"]) == true

    cond do
      not can_view_device?(scope) ->
        put_flash(socket, :error, "You are not authorized to start a camera relay")

      not is_nil(socket.assigns.active_camera_relay_session) ->
        put_flash(socket, :error, "Close the current camera relay before starting another")

      true ->
        case CameraRelayRuntime.request_open(camera_source_id, stream_profile_id, scope, insecure_skip_verify) do
          {:ok, session} ->
            socket
            |> clear_flash(:error)
            |> assign(:active_camera_relay_session, session)
            |> assign(:last_camera_relay_session, nil)
            |> tap(fn _socket -> CameraRelayRuntime.schedule_refresh(session.id) end)
            |> put_flash(:info, "Camera relay requested")

          {:error, reason} ->
            put_flash(socket, :error, CameraRelayRuntime.format_error(reason, &format_ash_error/1))
        end
    end
  end

  def close_camera_relay(socket) do
    scope = socket.assigns.current_scope
    active_session = socket.assigns.active_camera_relay_session

    cond do
      not can_view_device?(scope) ->
        put_flash(socket, :error, "You are not authorized to stop a camera relay")

      is_nil(active_session) ->
        socket

      true ->
        case CameraRelayRuntime.request_close(active_session.id, scope) do
          {:ok, session} ->
            socket
            |> assign(:active_camera_relay_session, session)
            |> tap(fn _socket -> CameraRelayRuntime.schedule_refresh(session.id) end)
            |> put_flash(:info, "Camera relay closing")

          {:error, reason} ->
            put_flash(socket, :error, CameraRelayRuntime.format_error(reason, &format_ash_error/1))
        end
    end
  end

  def validate_device(socket, params) do
    assign(socket, :device_form, to_form(params, as: :device))
  end

  def save_device(socket, params) do
    scope = socket.assigns.current_scope
    device_uid = socket.assigns.device_uid

    case DeviceResourceData.update(scope, device_uid, params) do
      {:ok, _device} ->
        socket
        |> assign(:editing, false)
        |> put_flash(:info, "Device updated successfully.")
        |> push_patch(to: ~p"/devices/#{device_uid}")

      {:error, %Invalid{} = error} ->
        put_flash(socket, :error, format_ash_error(error))

      {:error, reason} ->
        put_flash(socket, :error, "Failed to update device: #{inspect(reason)}")
    end
  end

  def change_snmp_form(socket, params) do
    current = socket.assigns.snmp_credential_form.source || %{}
    updated = Map.merge(current, params)

    assign(socket, :snmp_credential_form, to_form(updated, as: :snmp))
  end

  def save_snmp_credentials(socket, params) do
    scope = socket.assigns.current_scope
    device_uid = socket.assigns.device_uid
    editing = not is_nil(socket.assigns.device_snmp_credential)
    normalized = SNMPCredentialData.normalize_params(params, editing)

    if editing or SNMPCredentialData.params_present?(normalized) do
      case SNMPCredentialData.upsert(scope, device_uid, normalized) do
        {:ok, credential} ->
          socket
          |> assign(:device_snmp_credential, credential)
          |> assign(
            :snmp_credential_form,
            to_form(SNMPCredentialData.form_data(credential), as: :snmp)
          )
          |> put_flash(:info, "SNMP credentials saved")

        {:error, %Invalid{} = error} ->
          put_flash(socket, :error, format_ash_error(error))

        {:error, reason} ->
          put_flash(socket, :error, "Failed to save SNMP credentials: #{inspect(reason)}")
      end
    else
      put_flash(socket, :info, "Provide SNMP credentials to create an override")
    end
  end

  def clear_snmp_credentials(socket) do
    scope = socket.assigns.current_scope

    case socket.assigns.device_snmp_credential do
      nil ->
        socket

      credential ->
        case SNMPCredentialData.destroy(credential, scope) do
          :ok ->
            socket
            |> assign(:device_snmp_credential, nil)
            |> assign(:snmp_credential_form, to_form(%{}, as: :snmp))
            |> put_flash(:info, "SNMP credential override cleared")

          {:error, reason} ->
            put_flash(socket, :error, "Failed to clear SNMP credentials: #{inspect(reason)}")
        end
    end
  end

  def format_ash_error(%Invalid{errors: errors}) do
    Enum.map_join(errors, ", ", &format_single_ash_error/1)
  end

  def format_ash_error(error), do: inspect(error)

  defp device_form_data(nil), do: %{}

  defp device_form_data(device_row) do
    %{
      "hostname" => Map.get(device_row, "hostname", ""),
      "ip" => Map.get(device_row, "ip", ""),
      "type" => Map.get(device_row, "type", ""),
      "vendor_name" => Map.get(device_row, "vendor_name", ""),
      "model" => Map.get(device_row, "model", ""),
      "is_managed" => Map.get(device_row, "is_managed", false),
      "is_trusted" => Map.get(device_row, "is_trusted", false),
      "tags" => DeviceFormData.format_tags(Map.get(device_row, "tags"))
    }
  end

  defp normalize_agent_id(agent_id) do
    agent_id
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp can_view_device?(scope), do: RBAC.can?(scope, "devices.view")

  defp device_show_path(socket, device_uid) do
    tab =
      case socket.assigns.active_tab do
        :details -> nil
        "details" -> nil
        other -> to_string(other)
      end

    params =
      %{}
      |> maybe_put_param("q", Map.get(socket.assigns.srql || %{}, :query))
      |> maybe_put_param("tab", tab)
      |> maybe_put_param("return_to", Map.get(socket.assigns, :devices_return_path))

    ~p"/devices/#{device_uid}?#{params}"
  end

  defp maybe_put_param(params, _key, value) when value in [nil, ""], do: params
  defp maybe_put_param(params, key, value), do: Map.put(params, key, value)

  defp format_single_ash_error(%Ash.Error.Changes.InvalidAttribute{field: field, message: msg}), do: "#{field}: #{msg}"
  defp format_single_ash_error(%Ash.Error.Changes.Required{field: field}), do: "#{field} is required"

  defp format_single_ash_error(%Ash.Error.Changes.InvalidChanges{fields: fields, message: msg})
       when is_list(fields) and fields != [] and is_binary(msg) do
    "#{Enum.map_join(fields, ", ", &to_string/1)}: #{msg}"
  end

  defp format_single_ash_error(%{message: msg}) when is_binary(msg), do: msg
  defp format_single_ash_error(err), do: inspect(err)
end
