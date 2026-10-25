defmodule ServiceRadarWebNGWeb.Settings.AvailabilityRolloutComponents do
  @moduledoc """
  The merged availability rollout panel on the Availability Sources settings page:
  the deployment's availability mode, its mode control (`auto`, `hold_legacy`,
  `hold_shadow`), and the last readiness evaluation core recorded for the automatic
  cutover. A control pinned through the Helm value `core.availability.modeControl` is
  shown read-only.
  """

  use Phoenix.Component

  import ServiceRadarWebNGWeb.CoreComponents, only: [icon: 1]
  import ServiceRadarWebNGWeb.UIComponents, only: [ui_badge: 1, ui_button: 1]

  alias ServiceRadar.Inventory.Availability.ModeControl

  @modes %{
    legacy: {"Legacy", "ghost"},
    shadow: {"Shadow", "info"},
    cutover: {"Cutting over", "warning"},
    authoritative: {"Merged", "success"}
  }

  @controls [
    {:auto, "Automatic", "Move to merged availability once the readiness checks pass.", nil},
    {:hold_shadow, "Hold in shadow", "Compute merged availability without showing it.",
     "Hold merged availability in shadow? A completed cutover is rolled back first."},
    {:hold_legacy, "Hold legacy", "Keep, or roll back to, legacy availability.",
     "Hold legacy availability? A completed cutover is rolled back."}
  ]

  @conditions [
    {"capture_backfill", "Evidence backfill finished"},
    {"shadow_resolve", "Every device resolved in shadow"},
    {"invalidation_backlog", "Resolution backlog drained"},
    {"sweep_groups", "Every active sweep group ran in shadow"},
    {"policy_violations", "No negative-control policy violations"}
  ]

  attr :setting, :map, default: nil, doc: "the availability settings row, or nil before it loads"
  attr :can_edit, :boolean, default: false

  def rollout_panel(assigns) do
    setting = assigns.setting
    pinned = setting && setting.mode_control_pin

    assigns =
      assigns
      |> assign(:pinned, pinned)
      |> assign(:active_control, active_control(setting))
      |> assign(:controls, @controls)
      |> assign(:mode, setting && Map.get(@modes, setting.mode))
      |> assign(:conditions, conditions(setting))

    ~H"""
    <section
      id="availability-rollout"
      class="rounded-lg border border-sr-line bg-sr-surface p-4 text-sm"
    >
      <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h2 class="text-base font-semibold">Merged availability</h2>
          <p class="max-w-3xl text-sr-muted">
            Core moves to merged availability on its own once the checks below pass. After the
            cutover, devices with no availability evidence show Unknown instead of Offline.
          </p>
        </div>
        <.ui_badge :if={@mode} id="availability-rollout-mode" variant={elem(@mode, 1)}>
          {elem(@mode, 0)}
        </.ui_badge>
      </div>

      <p :if={is_nil(@setting)} class="mt-3 text-sr-muted">Loading...</p>

      <div :if={@setting} class="mt-4 space-y-4">
        <div
          :if={@pinned}
          id="availability-rollout-pinned"
          class="flex items-center gap-2 text-sr-muted"
        >
          <.icon name="hero-lock-closed" class="size-4" />
          <span>
            Pinned to <span class="font-mono">{@pinned}</span>
            by the Helm value <span class="font-mono">core.availability.modeControl</span>.
          </span>
        </div>

        <div class="grid gap-2 sm:grid-cols-3">
          <div :for={{control, label, help, confirm} <- @controls} class="space-y-1">
            <.ui_button
              id={"availability-rollout-control-#{control}"}
              type="button"
              size="sm"
              variant={if @active_control == control, do: "primary", else: "ghost"}
              active={@active_control == control}
              aria-pressed={to_string(@active_control == control)}
              disabled={not is_nil(@pinned) or not @can_edit}
              phx-click="set_mode_control"
              phx-value-mode={control}
              data-confirm={confirm}
            >
              {label}
            </.ui_button>
            <p class="text-xs text-sr-muted">{help}</p>
          </div>
        </div>

        <div :if={@conditions != []}>
          <div class="text-xs uppercase tracking-wide text-sr-muted">Readiness</div>
          <ul class="mt-2 space-y-1">
            <li
              :for={{name, label, met} <- @conditions}
              id={"availability-rollout-condition-#{name}"}
              data-met={to_string(met)}
              class="flex items-center gap-2"
            >
              <.icon
                name={if met, do: "hero-check-circle", else: "hero-clock"}
                class={["size-4", if(met, do: "text-success", else: "text-warning")]}
              />
              <span>{label}</span>
            </li>
          </ul>
        </div>
      </div>
    </section>
    """
  end

  # A pin wins over the stored control, so the pinned value is the one in effect.
  defp active_control(nil), do: nil

  defp active_control(setting) do
    case ModeControl.parse(setting.mode_control_pin) do
      {:ok, control} -> control
      :error -> setting.mode_control
    end
  end

  defp conditions(%{readiness: %{"conditions" => conditions}}) when is_map(conditions) do
    for {name, label} <- @conditions, Map.has_key?(conditions, name) do
      {name, label, get_in(conditions, [name, "met"]) == true}
    end
  end

  defp conditions(_setting), do: []
end
