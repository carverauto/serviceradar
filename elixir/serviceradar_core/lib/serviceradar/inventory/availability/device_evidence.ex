defmodule ServiceRadar.Inventory.Availability.DeviceEvidence do
  @moduledoc """
  The current availability evidence record per device, source kind, source instance and
  reporter agent (`device_availability_evidence`, design Tier 1b).

  Non-probe sources submit through `ServiceRadar.Inventory.Availability.record_evidence/2`,
  which writes on change only. Agent reachability probes are never stored here; they
  stay in the per-agent ledger, `ServiceRadar.Inventory.DeviceAgentAvailability`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "device_availability_evidence"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :list_by_device, action: :by_device, args: [:device_uid]
  end

  actions do
    defaults [:read]

    read :by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid))
      prepare build(sort: [source_kind: :asc, source_instance: :asc, reporter_agent_id: :asc])
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
  end

  attributes do
    attribute :device_uid, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :source_kind, :string, primary_key?: true, allow_nil?: false, public?: true

    attribute :source_instance, :string,
      primary_key?: true,
      allow_nil?: false,
      default: "",
      public?: true,
      constraints: [allow_empty?: true, trim?: false]

    attribute :reporter_agent_id, :string,
      primary_key?: true,
      allow_nil?: false,
      default: "",
      public?: true,
      constraints: [allow_empty?: true, trim?: false]

    attribute :authority_class, :string, allow_nil?: false, public?: true
    attribute :state, :string, allow_nil?: false, public?: true
    attribute :observed_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :state_since, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :confirmations, :integer, allow_nil?: false, default: 1, public?: true
    attribute :reporter_eligible, :boolean, allow_nil?: false, default: true, public?: true
    attribute :detail, :map, allow_nil?: false, default: %{}, public?: true
    attribute :updated_at, :utc_datetime_usec, allow_nil?: false, public?: true
  end
end
