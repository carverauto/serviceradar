defmodule ServiceRadarWebNGWeb.DeviceLive.IndexView.BulkModals do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  # Bulk Edit Modal Component
  attr(:form, :any, required: true)
  attr(:selected_count, :integer, required: true)

  def bulk_edit_modal(assigns) do
    ~H"""
    <dialog id="bulk_edit_modal" class="modal modal-open">
      <div class="modal-box max-w-lg">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_bulk_edit_modal"
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-bold">Bulk Edit Devices</h3>
        <p class="py-2 text-sm text-base-content/70">
          Apply tags to {@selected_count} selected device(s).
        </p>

        <.form for={@form} id="bulk-tags-form" phx-submit="apply_bulk_tags" class="space-y-4">
          <div>
            <label class="label">
              <span class="label-text font-medium">Tags</span>
              <span class="label-text-alt text-base-content/50">key or key=value</span>
            </label>
            <.input
              type="textarea"
              field={@form[:tags]}
              class="textarea textarea-bordered w-full font-mono text-sm"
              rows="4"
              placeholder="env=prod\ncritical\nregion=us-east"
            />
          </div>

          <div class="flex justify-end gap-2 pt-2">
            <button type="button" phx-click="close_bulk_edit_modal" class="btn btn-ghost">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">
              Apply Tags
            </button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_bulk_edit_modal">close</button>
      </form>
    </dialog>
    """
  end

  # Bulk Delete Modal Component
  attr(:selected_count, :integer, required: true)

  def bulk_delete_modal(assigns) do
    ~H"""
    <dialog id="bulk_delete_modal" class="modal modal-open">
      <div class="modal-box max-w-lg">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_bulk_delete_modal"
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-bold text-error">Delete Devices</h3>
        <p class="py-2 text-sm text-base-content/70">
          This will hide {@selected_count} selected device(s) from inventory. They can be restored
          later.
        </p>

        <div class="flex justify-end gap-2 pt-2">
          <button type="button" phx-click="close_bulk_delete_modal" class="btn btn-ghost">
            Cancel
          </button>
          <button type="button" phx-click="confirm_bulk_delete" class="btn btn-error">
            Delete Devices
          </button>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_bulk_delete_modal">close</button>
      </form>
    </dialog>
    """
  end

  attr(:form, :any, required: true)
  attr(:agent_options, :list, required: true)
  attr(:selected_count, :integer, required: true)

  def bulk_availability_source_modal(assigns) do
    ~H"""
    <dialog id="bulk_availability_source_modal" class="modal modal-open">
      <div class="modal-box max-w-lg">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_bulk_availability_source_modal"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </form>

        <h3 class="text-lg font-bold">Set Availability Source</h3>
        <p class="py-2 text-sm text-base-content/70">
          Select the canonical agent for {@selected_count} selected device(s), or clear the
          override to use fallback evaluation.
        </p>

        <.form
          for={@form}
          id="bulk-availability-source-form"
          phx-submit="apply_bulk_availability_source"
          class="space-y-4"
        >
          <.input
            field={@form[:agent_id]}
            type="select"
            label="Canonical agent"
            prompt="Fallback: any fresh agent"
            options={@agent_options}
          />

          <div class="flex justify-end gap-2 pt-2">
            <button
              type="button"
              phx-click="close_bulk_availability_source_modal"
              class="btn btn-ghost"
            >
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">
              <.icon name="hero-check" class="size-4" /> Apply
            </button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_bulk_availability_source_modal">close</button>
      </form>
    </dialog>
    """
  end
end
