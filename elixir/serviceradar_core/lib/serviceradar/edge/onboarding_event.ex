defmodule ServiceRadar.Edge.OnboardingEvent do
  @moduledoc """
  Audit event resource for edge onboarding packages.

  Stored in a TimescaleDB hypertable with composite primary key
  (event_time, package_id) for efficient time-series queries.

  ## Event Types

  - `created` - Package was created
  - `delivered` - Package was downloaded
  - `activated` - Edge component activated
  - `revoked` - Package was revoked
  - `deleted` - Package was soft deleted
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "edge_onboarding_events"
    repo ServiceRadar.Repo
  end

  code_interface do
    define :record, action: :record
    define :by_package, action: :by_package, args: [:package_id]
  end

  actions do
    defaults [:read]

    read :by_package do
      argument :package_id, :uuid, allow_nil?: false
      filter expr(package_id == ^arg(:package_id))
    end

    read :recent do
      argument :since, :utc_datetime, allow_nil?: false
      filter expr(event_time >= ^arg(:since))
    end

    read :by_type do
      argument :event_type, :atom, allow_nil?: false
      filter expr(event_type == ^arg(:event_type))
    end

    create :record do
      description "Record a new audit event"
      accept [:event_time, :package_id, :event_type, :actor, :source_ip, :details_json]

      change fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :event_time) do
          nil -> Ash.Changeset.change_attribute(changeset, :event_time, DateTime.utc_now())
          _ -> changeset
        end
      end
    end
  end

  policies do
    # Super admins bypass all policies
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # Admins and operators can read events
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    # Only admins can create events directly (normally done via package actions)
    policy action(:record) do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  attributes do
    # Composite primary key for TimescaleDB hypertable
    attribute :event_time, :utc_datetime_usec do
      allow_nil? false
      primary_key? true
      public? true
      description "Event timestamp (hypertable partition key)"
    end

    attribute :package_id, :uuid do
      allow_nil? false
      primary_key? true
      public? true
      description "Associated package ID"
    end

    attribute :event_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:created, :delivered, :activated, :revoked, :deleted, :expired]
      description "Type of lifecycle event"
    end

    attribute :actor, :string do
      public? true
      description "User or system that triggered the event"
    end

    attribute :source_ip, :string do
      public? true
      description "Source IP address of the request"
    end

    attribute :details_json, :map do
      default %{}
      public? true
      description "Additional event details"
    end
  end

  relationships do
    belongs_to :package, ServiceRadar.Edge.OnboardingPackage do
      source_attribute :package_id
      destination_attribute :id
      allow_nil? false
    end
  end
end
