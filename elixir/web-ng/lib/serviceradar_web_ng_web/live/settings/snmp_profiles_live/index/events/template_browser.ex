defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Events.TemplateBrowser do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.SNMPProfiles.BuiltinTemplates
  alias ServiceRadar.SNMPProfiles.SNMPOIDTemplate
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Templates

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

        case Templates.create_custom_template(scope, attrs) do
          {:ok, custom_template} ->
            {:noreply, put_flash(socket, :info, "Created custom template: #{custom_template.name}")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to create custom template")}
        end
    end
  end

  # Custom Template Modal Event Handlers
end
