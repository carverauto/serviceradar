defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.View.TemplateBrowserModal do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Provenance,
    only: [provenance_badge: 1]

  alias ServiceRadar.SNMPProfiles.BuiltinTemplates

  attr :search, :string, default: ""
  attr :selected_vendor, :string, default: "standard"
  attr :custom_templates, :list, default: []
  attr :package_names, :map, default: %{}

  def template_browser_modal(assigns) do
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
            is_custom: true,
            plugin_package_id: Map.get(t, :plugin_package_id)
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
    <dialog id="template_browser_modal" class="sr-ui-modal sr-ui-modal-open" phx-hook="DialogTopLayer">
      <div class="sr-ui-modal-box sr-ui-modal-box-lg max-h-[80vh]">
        <form method="dialog">
          <.ui_icon_button
            type="button"
            phx-click="close_template_browser"
            size="sm"
            variant="ghost"
            class="absolute right-2 top-2"
          >
            x
          </.ui_icon_button>
        </form>

        <h3 class="font-bold text-lg mb-4">OID Templates</h3>
        <p class="text-sm text-sr-muted mb-4">
          Select a template to add pre-configured OIDs for common device types.
        </p>

        <!-- Search and Vendor Filter -->
        <div class="flex flex-col md:flex-row gap-4 mb-4">
          <div class="flex-1">
            <input
              type="text"
              value={@search}
              placeholder="Search templates..."
              class={ui_field_class(class: "w-full")}
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
        <div class="sr-ui-tabs sr-ui-tabs-boxed mb-4">
          <%= for vendor <- @vendors do %>
            <button
              type="button"
              class={"sr-ui-tab #{if @selected_vendor == vendor.id, do: "sr-ui-tab-active", else: ""}"}
              phx-click="select_vendor"
              phx-value-vendor={vendor.id}
            >
              {vendor.name}
            </button>
          <% end %>
        </div>

        <!-- Templates List -->
        <div class="overflow-y-auto max-h-[40vh] space-y-2">
          <div :if={@templates == [] && !@is_custom_tab} class="text-center py-8 text-sr-muted">
            <.icon name="hero-document-magnifying-glass" class="size-10 mx-auto mb-2 opacity-50" />
            <p>No templates found</p>
          </div>

          <div :if={@templates == [] && @is_custom_tab} class="text-center py-8 text-sr-muted">
            <.icon name="hero-document-plus" class="size-10 mx-auto mb-2 opacity-50" />
            <p>No custom templates yet</p>
            <p class="text-xs mt-1">Create your own template or copy from a built-in template</p>
          </div>

          <%= for template <- @templates do %>
            <div class="flex items-center justify-between p-3 bg-sr-subtle/30 rounded-lg hover:bg-sr-subtle/50">
              <div class="flex-1">
                <div class="flex items-center gap-2">
                  <div class="font-medium text-sm">{template.name}</div>
                  <.provenance_badge
                    :if={template.is_custom}
                    id={"snmp-template-#{template.id}-provenance"}
                    row={template}
                    package_names={@package_names}
                  />
                </div>
                <p :if={template.description} class="text-xs text-sr-muted mt-0.5">
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
        <div class="sr-ui-modal-action">
          <.ui_button type="button" variant="ghost" phx-click="close_template_browser">
            Close
          </.ui_button>
        </div>
      </div>
      <form method="dialog" class="sr-ui-modal-backdrop">
        <button type="button" phx-click="close_template_browser">close</button>
      </form>
    </dialog>
    """
  end
end
