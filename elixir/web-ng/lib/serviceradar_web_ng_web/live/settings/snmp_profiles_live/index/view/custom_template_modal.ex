defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.View.CustomTemplateModal do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  attr :form, :any, required: true
  attr :oids, :list, default: []
  attr :editing, :any, default: nil

  def custom_template_modal(assigns) do
    categories = [
      {"interface", "Interface"},
      {"cpu-memory", "CPU/Memory"},
      {"environment", "Environment"},
      {"bgp", "BGP"},
      {"system", "System"},
      {"other", "Other"}
    ]

    data_types = [
      {"gauge", "Gauge"},
      {"counter", "Counter"},
      {"string", "String"},
      {"integer", "Integer"},
      {"timeticks", "TimeTicks"}
    ]

    assigns =
      assigns
      |> assign(:categories, categories)
      |> assign(:data_types, data_types)

    ~H"""
    <dialog id="custom_template_modal" class="modal modal-open">
      <div class="modal-box max-w-2xl max-h-[85vh]">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            type="button"
            phx-click="close_custom_template_modal"
          >
            x
          </button>
        </form>

        <h3 class="font-bold text-lg mb-4">
          {if @editing, do: "Edit Custom Template", else: "New Custom Template"}
        </h3>

        <.form
          for={@form}
          phx-change="validate_custom_template"
          phx-submit="save_custom_template"
          class="space-y-4"
        >
          <!-- Template Name -->
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Template Name</span>
            </label>
            <.input
              type="text"
              field={@form[:name]}
              class="input input-bordered w-full"
              placeholder="e.g., My Router Monitoring"
            />
          </div>
          
    <!-- Description -->
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Description</span>
            </label>
            <.input
              type="textarea"
              field={@form[:description]}
              class="textarea textarea-bordered w-full"
              rows="2"
              placeholder="Describe what this template monitors..."
            />
          </div>
          
    <!-- Category -->
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Category</span>
            </label>
            <select name={@form[:category].name} class="select select-bordered w-full">
              <option value="">Select a category...</option>
              <%= for {value, label} <- @categories do %>
                <option value={value} selected={@form[:category].value == value}>{label}</option>
              <% end %>
            </select>
          </div>
          
    <!-- OIDs Section -->
          <div class="form-control">
            <div class="flex items-center justify-between mb-2">
              <label class="label">
                <span class="label-text font-medium">OID Definitions</span>
              </label>
              <.ui_button
                type="button"
                variant="ghost"
                size="sm"
                phx-click="add_template_oid"
              >
                <.icon name="hero-plus" class="size-4" /> Add OID
              </.ui_button>
            </div>

            <div
              :if={@oids == []}
              class="text-center py-6 text-base-content/60 bg-base-200/30 rounded-lg"
            >
              <.icon name="hero-variable" class="size-8 mx-auto mb-2 opacity-50" />
              <p class="text-sm">No OIDs defined</p>
              <p class="text-xs mt-1">Add OIDs to include in this template</p>
            </div>

            <div :if={@oids != []} class="space-y-3 max-h-[30vh] overflow-y-auto">
              <%= for {oid, idx} <- Enum.with_index(@oids) do %>
                <div class="flex items-start gap-2 p-3 bg-base-200/30 rounded-lg">
                  <div class="flex-1 grid grid-cols-2 gap-2">
                    <!-- OID -->
                    <div>
                      <label class="label py-0">
                        <span class="label-text text-xs">OID</span>
                      </label>
                      <input
                        type="text"
                        value={oid["oid"]}
                        placeholder=".1.3.6.1.2.1..."
                        class="input input-bordered input-sm w-full font-mono text-xs"
                        phx-blur="update_template_oid"
                        phx-value-index={idx}
                        phx-value-field="oid"
                        name="oid"
                      />
                    </div>
                    
    <!-- Name -->
                    <div>
                      <label class="label py-0">
                        <span class="label-text text-xs">Name</span>
                      </label>
                      <input
                        type="text"
                        value={oid["name"]}
                        placeholder="e.g., ifInOctets"
                        class="input input-bordered input-sm w-full text-xs"
                        phx-blur="update_template_oid"
                        phx-value-index={idx}
                        phx-value-field="name"
                        name="name"
                      />
                    </div>
                    
    <!-- Data Type -->
                    <div>
                      <label class="label py-0">
                        <span class="label-text text-xs">Data Type</span>
                      </label>
                      <select
                        class="select select-bordered select-sm w-full text-xs"
                        phx-change="update_template_oid"
                        phx-value-index={idx}
                        phx-value-field="data_type"
                        name="data_type"
                      >
                        <%= for {value, label} <- @data_types do %>
                          <option value={value} selected={oid["data_type"] == value}>{label}</option>
                        <% end %>
                      </select>
                    </div>
                    
    <!-- Scale -->
                    <div>
                      <label class="label py-0">
                        <span class="label-text text-xs">Scale</span>
                      </label>
                      <input
                        type="text"
                        value={oid["scale"]}
                        placeholder="1.0"
                        class="input input-bordered input-sm w-full text-xs"
                        phx-blur="update_template_oid"
                        phx-value-index={idx}
                        phx-value-field="scale"
                        name="scale"
                      />
                    </div>
                    
    <!-- Delta checkbox -->
                    <div class="col-span-2 flex items-center gap-2 mt-1">
                      <input
                        type="checkbox"
                        checked={oid["delta"]}
                        class="checkbox checkbox-sm"
                        phx-click="update_template_oid"
                        phx-value-index={idx}
                        phx-value-field="delta"
                        phx-value-delta={if oid["delta"], do: "false", else: "true"}
                        name="delta"
                      />
                      <span class="text-xs text-base-content/70">
                        Calculate delta (rate of change)
                      </span>
                    </div>
                  </div>
                  
    <!-- Remove button -->
                  <.ui_icon_button
                    type="button"
                    variant="ghost"
                    size="sm"
                    phx-click="remove_template_oid"
                    phx-value-index={idx}
                    title="Remove OID"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </.ui_icon_button>
                </div>
              <% end %>
            </div>
          </div>
          
    <!-- Modal Actions -->
          <div class="modal-action">
            <.ui_button type="button" variant="ghost" phx-click="close_custom_template_modal">
              Cancel
            </.ui_button>
            <.ui_button type="submit" variant="primary">
              {if @editing, do: "Update Template", else: "Create Template"}
            </.ui_button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="close_custom_template_modal">close</button>
      </form>
    </dialog>
    """
  end
end
