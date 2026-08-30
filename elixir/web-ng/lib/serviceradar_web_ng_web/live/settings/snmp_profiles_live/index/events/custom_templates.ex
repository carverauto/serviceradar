defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Events.CustomTemplates do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias AshPhoenix.Form
  alias ServiceRadar.SNMPProfiles.SNMPOIDTemplate
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Data
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Templates

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
              "mode" => Map.get(oid, "mode", "get"),
              "max_rows" => Map.get(oid, "max_rows"),
              "walk_timeout_seconds" => Map.get(oid, "walk_timeout_seconds"),
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
          "scale" => Templates.parse_float(Map.get(oid, "scale", "1.0")),
          "delta" => Map.get(oid, "delta", false),
          "mode" => Map.get(oid, "mode", "get"),
          "max_rows" => Map.get(oid, "max_rows"),
          "walk_timeout_seconds" => Map.get(oid, "walk_timeout_seconds")
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
         |> Data.assign_custom_templates(scope)
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
             |> Data.assign_custom_templates(scope)
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
      "mode" => "get",
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

  # SNMP test-connection probe result. The probe runs via
  # Task.Supervisor.async_nolink (off the LiveView process), so it delivers a
  # {ref, result} message on success and a {:DOWN, ref, ...} message on crash.
end
