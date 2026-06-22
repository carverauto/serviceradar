defmodule ServiceRadarWebNGWeb.DeviceLive.IndexView.DeviceModal do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  # Add Device Modal Component
  attr(:form, :any, required: true)

  def add_device_modal(assigns) do
    ~H"""
    <dialog id="add_device_modal" class="modal modal-open">
      <div class="modal-box max-w-lg">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_add_device_modal"
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-bold">Add Device</h3>
        <p class="py-2 text-sm text-base-content/70">
          Add a new device to your inventory. For automatic discovery, use Network Sweeps.
        </p>

        <.form
          for={@form}
          id="add-device-form"
          phx-change="validate_device"
          phx-submit="save_device"
          class="space-y-4"
        >
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Hostname</span>
            </label>
            <input
              type="text"
              name="device[hostname]"
              value={@form[:hostname].value}
              class="input input-bordered"
              placeholder="server01.example.com"
            />
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">IP Address</span>
            </label>
            <input
              type="text"
              name="device[ip]"
              value={@form[:ip].value}
              class="input input-bordered"
              placeholder="192.168.1.100"
            />
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Device Type</span>
            </label>
            <select name="device[type]" class="select select-bordered">
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

          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Tags</span>
              <span class="label-text-alt text-base-content/50">Optional, one per line</span>
            </label>
            <textarea
              name="device[tags]"
              class="textarea textarea-bordered h-20"
              placeholder="env=production&#10;team=infrastructure"
            >{@form[:tags].value}</textarea>
          </div>

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="close_add_device_modal">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">
              <.icon name="hero-plus" class="size-4" /> Add Device
            </button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_add_device_modal">close</button>
      </form>
    </dialog>
    """
  end
end
