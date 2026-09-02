defmodule ServiceRadarWebNGWeb.DeviceLive.IndexView.DeviceModal do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  # Add Device Modal Component
  attr(:form, :any, required: true)
  attr(:partition_options, :list, default: [{"Default", "default"}])

  def add_device_modal(assigns) do
    ~H"""
    <.ui_modal id="add_device_modal" size="form" on_cancel="close_add_device_modal">
      <:title>Add Device</:title>

      <p class="text-sm text-sr-muted">
        Add a new device to your inventory. For automatic discovery, use Network Sweeps.
      </p>

      <.form
        for={@form}
        id="add-device-form"
        phx-change="validate_device"
        phx-submit="save_device"
        class="space-y-4"
      >
        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Hostname</span>
          </label>
          <input
            type="text"
            name="device[hostname]"
            value={@form[:hostname].value}
            class={ui_field_class()}
            placeholder="server01.example.com"
          />
        </div>

        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">IP Address</span>
          </label>
          <input
            type="text"
            name="device[ip]"
            value={@form[:ip].value}
            class={ui_field_class()}
            placeholder="192.168.1.100"
          />
        </div>

        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Partition</span>
            <span class="text-xs text-sr-muted">default keeps isolation copies</span>
          </label>
          <input
            type="text"
            name="device[partition]"
            value={@form[:partition].value || "default"}
            list="add-device-partition-slugs"
            class={ui_field_class()}
            placeholder="default"
            autocomplete="off"
          />
          <datalist id="add-device-partition-slugs">
            <%= for {name, slug} <- @partition_options do %>
              <option value={slug}>{name}</option>
            <% end %>
          </datalist>
        </div>

        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Device Type</span>
          </label>
          <select name="device[type]" class={ui_field_class()}>
            <option value="">Select type...</option>
            <option value="server">Server</option>
            <option value="workstation">Workstation</option>
            <option value="router">Router</option>
            <option value="switch">Switch</option>
            <option value="firewall">Firewall</option>
            <option value="printer">Printer</option>
            <option value="other">Other</option>
          </select>
        </div>

        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Tags</span>
            <span class="text-xs text-sr-muted">Optional, one per line</span>
          </label>
          <textarea
            name="device[tags]"
            class={ui_field_class(class: "h-20 py-2.5")}
            placeholder="env=production&#10;team=infrastructure"
          >{@form[:tags].value}</textarea>
        </div>

        <div class="flex justify-end gap-2 pt-2">
          <.ui_button type="button" phx-click="close_add_device_modal" size="sm" variant="ghost">
            Cancel
          </.ui_button>
          <.ui_button type="submit" size="sm" variant="primary">
            <.icon name="hero-plus" class="size-4" /> Add Device
          </.ui_button>
        </div>
      </.form>
    </.ui_modal>
    """
  end
end
