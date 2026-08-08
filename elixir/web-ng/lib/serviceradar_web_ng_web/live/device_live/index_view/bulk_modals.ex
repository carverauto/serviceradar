defmodule ServiceRadarWebNGWeb.DeviceLive.IndexView.BulkModals do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  # Bulk Edit Modal Component
  attr(:form, :any, required: true)
  attr(:selected_count, :integer, required: true)

  def bulk_edit_modal(assigns) do
    ~H"""
    <.ui_modal id="bulk_edit_modal" size="form" on_cancel="close_bulk_edit_modal">
      <:title>Bulk Edit Devices</:title>

      <p class="text-sm text-sr-muted">
        Apply tags to {@selected_count} selected device(s).
      </p>

      <.form for={@form} id="bulk-tags-form" phx-submit="apply_bulk_tags" class="space-y-4">
        <div>
          <label class="mb-1.5 flex items-center justify-between text-sm">
            <span class="font-medium text-sr-ink">Tags</span>
            <span class="text-xs text-sr-muted">key or key=value</span>
          </label>
          <.input
            type="textarea"
            field={@form[:tags]}
            class="w-full min-h-24 rounded-sr-control border border-sr-line bg-sr-control px-3.5 py-2.5 font-mono text-sm text-sr-ink shadow-sr-control outline-none focus-visible:ring-2 focus-visible:ring-sr-focus"
            rows="4"
            placeholder="env=prod\ncritical\nregion=us-east"
          />
        </div>

        <div class="flex justify-end gap-2 pt-2">
          <.ui_button type="button" phx-click="close_bulk_edit_modal" variant="ghost">
            Cancel
          </.ui_button>
          <.ui_button type="submit" variant="primary">
            Apply Tags
          </.ui_button>
        </div>
      </.form>
    </.ui_modal>
    """
  end

  # Bulk Delete Modal Component
  attr(:selected_count, :integer, required: true)

  def bulk_delete_modal(assigns) do
    ~H"""
    <.ui_modal id="bulk_delete_modal" size="form" on_cancel="close_bulk_delete_modal">
      <:title>
        <span class="text-rose-600 dark:text-rose-300">Delete Devices</span>
      </:title>

      <p class="text-sm text-sr-muted">
        This will hide {@selected_count} selected device(s) from inventory. They can be restored
        later.
      </p>

      <:actions>
        <.ui_button type="button" phx-click="close_bulk_delete_modal" variant="ghost">
          Cancel
        </.ui_button>
        <.ui_button type="button" phx-click="confirm_bulk_delete" variant="danger">
          Delete Devices
        </.ui_button>
      </:actions>
    </.ui_modal>
    """
  end

  attr(:form, :any, required: true)
  attr(:agent_options, :list, required: true)
  attr(:selected_count, :integer, required: true)

  def bulk_availability_source_modal(assigns) do
    ~H"""
    <.ui_modal
      id="bulk_availability_source_modal"
      size="form"
      on_cancel="close_bulk_availability_source_modal"
    >
      <:title>Set Availability Source</:title>

      <p class="text-sm text-sr-muted">
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
          <.ui_button type="button" phx-click="close_bulk_availability_source_modal" variant="ghost">
            Cancel
          </.ui_button>
          <.ui_button type="submit" variant="primary">
            <.icon name="hero-check" class="size-4" /> Apply
          </.ui_button>
        </div>
      </.form>
    </.ui_modal>
    """
  end
end
