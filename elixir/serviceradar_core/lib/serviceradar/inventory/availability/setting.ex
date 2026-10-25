defmodule ServiceRadar.Inventory.Availability.Setting do
  @moduledoc """
  The deployment's availability settings (`availability_settings`, design Decision 10):
  the mode (`legacy`, `shadow`, `cutover` or `authoritative`), the mode control that
  drives it, and the progression's bookkeeping. One row; a missing row reads as
  `legacy`.

  `:set_mode_control` is the only write here: the settings UI sets the control to
  `auto`, `hold_legacy` or `hold_shadow`, and it is refused while core runs with the
  control pinned (`mode_control_pin`, recorded by
  `ServiceRadar.Inventory.Availability.ProgressionWorker`). Call it through
  `ServiceRadar.Inventory.Availability.ModeControl.set/2`, which applies the new control
  at once. `ServiceRadar.Inventory.Availability.Mode` switches the mode under the
  draining advisory lock, the expiry job advances `expiry_watermark`, and
  `ServiceRadar.Inventory.Availability.Operator.transition_events/1` sets
  `transition_events`, which gates the resolver's `device.*` events.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "availability_settings"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]

    update :set_mode_control do
      accept [:mode_control]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()

    policy action(:set_mode_control) do
      forbid_if expr(not is_nil(mode_control_pin))

      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "settings.networks.manage"}
    end
  end

  attributes do
    attribute :singleton, :boolean, primary_key?: true, allow_nil?: false, default: true

    attribute :mode, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:legacy, :shadow, :cutover, :authoritative]]

    attribute :mode_control, :atom,
      allow_nil?: false,
      default: :auto,
      public?: true,
      constraints: [one_of: [:auto, :hold_legacy, :hold_shadow]]

    attribute :mode_control_pin, :string, public?: true
    attribute :shadow_entered_at, :utc_datetime_usec, public?: true
    attribute :shadow_resolved_at, :utc_datetime_usec, public?: true
    attribute :readiness, :map, public?: true
    attribute :readiness_checked_at, :utc_datetime_usec, public?: true
    attribute :expiry_watermark, :utc_datetime_usec, public?: true
    attribute :transition_events, :boolean, allow_nil?: false, default: false, public?: true
    attribute :updated_at, :utc_datetime_usec, allow_nil?: false, public?: true
  end
end
