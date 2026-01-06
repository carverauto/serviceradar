defmodule ServiceRadar.Identity.DeviceAliasState do
  @moduledoc """
  Device alias state tracking resource using AshStateMachine.

  Tracks the lifecycle of device aliases (IP addresses, service IDs, MAC addresses)
  with proper state transitions for audit and monitoring.

  ## Alias Lifecycle States

  - `:detected` - New alias first observed
  - `:confirmed` - Alias seen multiple times, considered stable
  - `:updated` - Alias metadata changed (e.g., new IP for same service)
  - `:stale` - Alias not seen recently
  - `:replaced` - Alias superseded by a new alias
  - `:archived` - Historical record, no longer active

  ## Usage

      # Create new alias state when detected
      {:ok, alias_state} = DeviceAliasState.create_detected(device_id, alias_type, alias_value, metadata)

      # Confirm alias after multiple sightings
      {:ok, alias_state} = DeviceAliasState.confirm(alias_state)

      # Mark as stale when not seen
      {:ok, alias_state} = DeviceAliasState.mark_stale(alias_state)
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine]

  postgres do
    table "device_alias_states"
    repo ServiceRadar.Repo
  end

  state_machine do
    initial_states [:detected]
    default_initial_state :detected
    state_attribute :state
    deprecated_states []

    transitions do
      # Alias lifecycle transitions
      transition :confirm, from: :detected, to: :confirmed
      transition :update_metadata, from: [:detected, :confirmed], to: :updated
      transition :mark_stale, from: [:detected, :confirmed, :updated], to: :stale
      transition :reactivate, from: :stale, to: :confirmed
      transition :replace, from: [:detected, :confirmed, :updated, :stale], to: :replaced
      transition :archive, from: [:stale, :replaced], to: :archived
    end
  end

  multitenancy do
    strategy :context
  end

  code_interface do
    define :list_by_device, action: :by_device, args: [:device_id]
    define :list_active_for_device, action: :active_for_device, args: [:device_id]
    define :lookup_by_value, action: :by_alias_value, args: [:alias_type, :alias_value]
    define :create_detected, action: :detect
    define :record_sighting, action: :record_sighting
    define :confirm, action: :confirm
    define :mark_stale, action: :mark_stale
    define :replace_alias, action: :replace, args: [:replaced_by_id]
    define :archive, action: :archive
  end

  actions do
    defaults [:read, :destroy]

    read :by_device do
      argument :device_id, :string, allow_nil?: false
      filter expr(device_id == ^arg(:device_id))
    end

    read :active_for_device do
      argument :device_id, :string, allow_nil?: false
      filter expr(device_id == ^arg(:device_id) and state in [:detected, :confirmed, :updated])
    end

    read :by_alias_value do
      argument :alias_type, :atom, allow_nil?: false
      argument :alias_value, :string, allow_nil?: false
      filter expr(alias_type == ^arg(:alias_type) and alias_value == ^arg(:alias_value))
    end

    read :stale do
      description "Aliases not seen recently"
      filter expr(state == :stale)
    end

    read :recently_seen do
      description "Aliases seen in the last hour"
      filter expr(last_seen_at > ago(1, :hour))
    end

    create :detect do
      description "Create a new alias detection"
      accept [:device_id, :partition, :alias_type, :alias_value, :metadata]

      change fn changeset, _context ->
        now = DateTime.utc_now()

        changeset
        |> Ash.Changeset.change_attribute(:first_seen_at, now)
        |> Ash.Changeset.change_attribute(:last_seen_at, now)
        |> Ash.Changeset.change_attribute(:sighting_count, 1)
      end
    end

    update :record_sighting do
      description "Record a new sighting and confirm if threshold is met"
      accept [:metadata]
      argument :confirm_threshold, :integer, default: 3

      change atomic_update(:last_seen_at, expr(now()))
      change atomic_update(:sighting_count, expr(sighting_count + 1))

      change atomic_update(
               :state,
               expr(
                 if state == :detected and sighting_count + 1 >= ^arg(:confirm_threshold) do
                   :confirmed
                 else
                   state
                 end
               )
             )
    end

    # State machine transition actions
    update :confirm do
      description "Confirm alias as stable (seen multiple times)"

      change transition_state(:confirmed)
      change set_attribute(:last_seen_at, &DateTime.utc_now/0)
    end

    update :update_metadata do
      description "Update alias metadata (triggers updated state)"
      accept [:metadata]

      change transition_state(:updated)
      change set_attribute(:last_seen_at, &DateTime.utc_now/0)
    end

    update :mark_stale do
      description "Mark alias as stale (not seen recently)"

      change transition_state(:stale)
    end

    update :reactivate do
      description "Reactivate a stale alias"

      change transition_state(:confirmed)
      change set_attribute(:last_seen_at, &DateTime.utc_now/0)
    end

    update :replace do
      description "Mark alias as replaced by a new alias"
      argument :replaced_by_id, :uuid
      require_atomic? false

      change transition_state(:replaced)

      change fn changeset, _context ->
        case Ash.Changeset.get_argument(changeset, :replaced_by_id) do
          nil -> changeset
          id -> Ash.Changeset.change_attribute(changeset, :replaced_by_alias_id, id)
        end
      end
    end

    update :archive do
      description "Archive a replaced or stale alias"

      change transition_state(:archived)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type(:create) do
      authorize_if always()
    end

    policy action_type(:update) do
      authorize_if always()
    end
  end

  changes do
    change ServiceRadar.Changes.AssignTenantId
  end

  attributes do
    uuid_primary_key :id

    attribute :device_id, :string do
      allow_nil? false
      public? true
      description "Canonical device ID this alias belongs to"
    end

    attribute :partition, :string do
      public? true
      description "Partition context for this alias"
    end

    attribute :alias_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:ip, :service_id, :mac, :collector_ip]
      description "Type of alias (ip, service_id, mac, collector_ip)"
    end

    attribute :alias_value, :string do
      allow_nil? false
      public? true
      description "The alias value (IP address, service ID, MAC, etc.)"
    end

    attribute :state, :atom do
      allow_nil? false
      default :detected
      public? true
      constraints one_of: [:detected, :confirmed, :updated, :stale, :replaced, :archived]
      description "Current lifecycle state"
    end

    attribute :first_seen_at, :utc_datetime do
      allow_nil? false
      public? true
      description "When this alias was first detected"
    end

    attribute :last_seen_at, :utc_datetime do
      allow_nil? false
      public? true
      description "When this alias was last seen"
    end

    attribute :sighting_count, :integer do
      default 1
      public? true
      description "Number of times this alias has been observed"
    end

    attribute :metadata, :map do
      default %{}
      public? true
      description "Additional alias metadata"
    end

    attribute :previous_alias_id, :uuid do
      public? true
      description "ID of the alias this one replaced"
    end

    attribute :replaced_by_alias_id, :uuid do
      public? true
      description "ID of the alias that replaced this one"
    end

    # Multi-tenancy
    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this alias belongs to"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :device, ServiceRadar.Inventory.Device do
      source_attribute :device_id
      destination_attribute :uid
      allow_nil? false
      public? true
    end
  end

  calculations do
    calculate :is_active, :boolean, expr(state in [:detected, :confirmed, :updated])

    calculate :age_seconds,
              :integer,
              expr(fragment("EXTRACT(EPOCH FROM (NOW() - ?))", first_seen_at))

    calculate :time_since_seen_seconds,
              :integer,
              expr(fragment("EXTRACT(EPOCH FROM (NOW() - ?))", last_seen_at))

    calculate :state_label,
              :string,
              expr(
                cond do
                  state == :detected -> "Detected"
                  state == :confirmed -> "Confirmed"
                  state == :updated -> "Updated"
                  state == :stale -> "Stale"
                  state == :replaced -> "Replaced"
                  state == :archived -> "Archived"
                  true -> "Unknown"
                end
              )

    calculate :state_color,
              :string,
              expr(
                cond do
                  state == :detected -> "blue"
                  state == :confirmed -> "green"
                  state == :updated -> "yellow"
                  state == :stale -> "orange"
                  state == :replaced -> "gray"
                  state == :archived -> "gray"
                  true -> "gray"
                end
              )
  end

  identities do
    identity :unique_device_alias, [:device_id, :alias_type, :alias_value]
  end
end
