defmodule ServiceRadar.Edge.ComponentCertificate do
  @moduledoc """
  Immutable public metadata for a certificate authorized by one issuance generation.
  Private keys never enter this resource. The full certificate fingerprint is the
  identity; serial numbers are display metadata and are not revocation selectors.
  """
  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  postgres do
    table "component_certificates"
    repo ServiceRadar.Repo
    schema "platform"

    custom_indexes do
      index [:component_id, :generation, :not_after]
    end
  end

  actions do
    defaults [:read]

    create :record_issuance do
      accept [
        :fingerprint,
        :issuer_fingerprint,
        :serial_number,
        :component_id,
        :role,
        :not_before,
        :not_after
      ]

      argument :expected_generation, :integer, allow_nil?: false, constraints: [min: 1]
      argument :host_agent_id, :string
      change ServiceRadar.Edge.Changes.GuardComponentCertificateIssuance
      validate attribute_in(:role, ["client", "upstream_client", "local_server"])
      validate compare(:not_after, greater_than: :not_before)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission({ActorHasPermission, permission: "settings.edge.manage"})
  end

  attributes do
    attribute :fingerprint, :string do
      primary_key? true
      allow_nil? false
      public? true
      constraints match: ~r/\A[0-9a-f]{64}\z/
    end

    attribute :issuer_fingerprint, :string do
      allow_nil? false
      public? true
      constraints match: ~r/\A[0-9a-f]{64}\z/
    end

    attribute :serial_number, :string, allow_nil?: false, public?: true
    attribute :generation, :integer, allow_nil?: false, public?: true, constraints: [min: 1]

    attribute :role, :string do
      allow_nil? false
      public? true
    end

    attribute :not_before, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :not_after, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :issued_at
  end

  relationships do
    belongs_to :component, ServiceRadar.Edge.ManagedComponent do
      source_attribute :component_id
      destination_attribute :component_id
      attribute_type :string
      allow_nil? false
      public? true
    end
  end
end
