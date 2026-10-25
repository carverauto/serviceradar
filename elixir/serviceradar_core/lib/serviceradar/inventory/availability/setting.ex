defmodule ServiceRadar.Inventory.Availability.Setting do
  @moduledoc """
  The deployment's availability mode (`availability_settings`, design Decision 10):
  `legacy`, `shadow`, `cutover` or `authoritative`. One row; a missing row reads as
  `legacy`.

  No action here writes it: `ServiceRadar.Inventory.Availability.Mode` switches the mode
  under the draining advisory lock, the expiry job advances `expiry_watermark`, and
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
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
  end

  attributes do
    attribute :singleton, :boolean, primary_key?: true, allow_nil?: false, default: true

    attribute :mode, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:legacy, :shadow, :cutover, :authoritative]]

    attribute :expiry_watermark, :utc_datetime_usec, public?: true
    attribute :transition_events, :boolean, allow_nil?: false, default: false, public?: true
    attribute :updated_at, :utc_datetime_usec, allow_nil?: false, public?: true
  end
end
