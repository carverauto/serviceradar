defmodule ServiceRadar.Inventory.Availability.LegacyValue do
  @moduledoc """
  The availability value the legacy writers computed (`device_availability_legacy`,
  design Decision 13), kept so canonical Armis northbound sources in `legacy` semantics
  and a rollback to `legacy` mode can read it after cutover.

  While the mode is `legacy` or `shadow` the legacy writers still own
  `ocsf_devices.is_available`, and a trigger copies each change of it here. The table is
  seeded for every device under the drained cutover boundary (stage c).
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "device_availability_legacy"
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
    attribute :device_uid, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :is_available, :boolean, public?: true
    attribute :updated_at, :utc_datetime_usec, allow_nil?: false, public?: true
  end
end
