defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.View.InventoryCleanup do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  attr :form, :any, default: nil
  attr :settings, :any, default: nil

  def render(assigns) do
    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface p-6 space-y-6">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h3 class="text-lg font-semibold text-sr-ink">Inventory Cleanup</h3>
          <p class="text-sm text-sr-muted">
            Purge soft-deleted devices after a retention window. Deleted devices can be restored
            if they are discovered again.
          </p>
        </div>
        <div class="flex items-center gap-2">
          <.ui_button
            variant="outline"
            size="sm"
            phx-click="run_cleanup_now"
            phx-confirm="Run cleanup now? This will permanently purge devices past the retention window."
          >
            <.icon name="hero-arrow-path" class="size-4" /> Run cleanup now
          </.ui_button>
        </div>
      </div>

      <div :if={is_nil(@form)} class={ui_alert_class("warning")}>
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <div>
          <div class="font-semibold">Cleanup settings unavailable</div>
          <div class="text-sm">Unable to load device cleanup settings.</div>
        </div>
      </div>

      <.form
        :if={not is_nil(@form)}
        for={@form}
        id="device-cleanup-form"
        phx-change="validate_cleanup_settings"
        phx-submit="save_cleanup_settings"
        class="grid grid-cols-1 md:grid-cols-2 gap-6"
      >
        <div class="space-y-4">
          <.input field={@form[:enabled]} type="checkbox" label="Enable scheduled cleanup" />
          <.input
            field={@form[:retention_days]}
            type="number"
            label="Retention (days)"
            min="1"
          />
          <.input
            field={@form[:cleanup_interval_minutes]}
            type="number"
            label="Cleanup interval (minutes)"
            min="5"
          />
          <.input
            field={@form[:batch_size]}
            type="number"
            label="Batch size"
            min="100"
          />
        </div>
        <div class="flex items-end">
          <div class="space-y-3">
            <p class="text-sm text-sr-muted">
              Cleanup runs on the configured interval and deletes devices that have been
              soft-deleted longer than the retention period.
            </p>
            <div class="flex gap-2">
              <.ui_button type="submit" variant="primary" size="sm">
                <.icon name="hero-check" class="size-4" /> Save settings
              </.ui_button>
            </div>
          </div>
        </div>
      </.form>
    </div>
    """
  end
end
