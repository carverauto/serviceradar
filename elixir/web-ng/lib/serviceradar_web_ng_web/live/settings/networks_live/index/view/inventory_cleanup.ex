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
            Expire ephemeral devices, then purge soft-deleted devices after a retention window.
            Expired and deleted devices are restored if they are discovered again.
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
          <.input
            field={@form[:ephemeral_expiry_enabled]}
            type="checkbox"
            label="Expire ephemeral devices"
          />
          <.input
            field={@form[:ephemeral_expiry_days]}
            type="number"
            label="Expire after unseen (days)"
            min="1"
          />
          <.input
            field={@form[:ephemeral_expiry_exclusion_query]}
            type="text"
            label="Never expire devices matching (SRQL)"
            placeholder="in:devices hostname:%lab%"
          />
          <.input
            field={@form[:ephemeral_expiry_max_fraction]}
            type="number"
            label="Largest share of live devices one pass may expire"
            min="0.01"
            max="1"
            step="0.01"
          />
          <.input
            field={@form[:ephemeral_expiry_guard_override]}
            type="checkbox"
            label="Allow the next passes to exceed that share"
          />
          <.input
            field={@form[:source_retirement_enabled]}
            type="checkbox"
            label="Retire source ids their source stopped reporting"
          />
          <.input
            field={@form[:source_retirement_absent_collections]}
            type="number"
            label="Retire after missing from consecutive exact collections"
            min="2"
            max="32"
          />
          <.input
            field={@form[:source_retirement_min_absence_hours]}
            type="number"
            label="And unreported for at least (hours)"
            min="1"
          />
          <.input
            field={@form[:source_retirement_max_fraction]}
            type="number"
            label="Largest share of a source's live devices one pass may retire"
            min="0.01"
            max="1"
            step="0.01"
          />
          <.input
            field={@form[:source_retirement_guard_override]}
            type="checkbox"
            label="Allow the next retirement pass to exceed that share"
          />
          <.input
            field={@form[:source_retired_grace_days]}
            type="number"
            label="Hide a device left with only retired ids for (days) before deleting it"
            min="1"
          />
          <.input
            field={@form[:max_successions_per_run]}
            type="number"
            label="Most source succession merges per reconciliation run"
            min="0"
          />
        </div>
        <div class="flex items-end">
          <div class="space-y-3">
            <p class="text-sm text-sr-muted">
              Cleanup runs on the configured interval and deletes devices that have been
              soft-deleted longer than the retention period.
            </p>
            <p class="text-sm text-sr-muted">
              An ephemeral device holds nothing stronger than a randomized MAC or an address.
              When one has not been seen for the expiry window it is soft-deleted with the
              reason "stale_ephemeral". Devices with an agent, a source-authoritative id, a
              hardware serial or a globally-unique MAC, and devices created by hand, never expire.
              Expiry is off until enabled, and a pass that would expire more than the allowed
              share of live devices is refused unless the override is on.
            </p>
            <p class="text-sm text-sr-muted">
              A source id (an Armis device id) retires once the source has left it out of the
              set number of consecutive exact collections and has not reported it for the set
              hours. The retired id moves to the identifier archive, where it still keeps its
              device from being matched to another id through a shared MAC. A retirement pass
              that would affect more than the allowed share of the source's live devices is
              refused; the override lets one pass through and then turns itself off.
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
