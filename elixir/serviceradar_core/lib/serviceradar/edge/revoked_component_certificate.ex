defmodule ServiceRadar.Edge.RevokedComponentCertificate do
  @moduledoc """
  Append-only revocation decisions. A nil fingerprint revokes an entire component
  generation. Old generations remain revoked after explicit re-enrollment.
  """
  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  postgres do
    table "revoked_component_certificates"
    repo ServiceRadar.Repo
    schema "platform"

    custom_indexes do
      index [:component_id, :generation]
    end
  end

  actions do
    defaults [:read]

    create :revoke do
      accept [:component_id, :generation, :fingerprint, :reason]

      change {ServiceRadar.Edge.Changes.StampCertificateActor, attribute: :revoked_by}
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    action_type_with_permission(
      [:read, :create],
      {ActorHasPermission, permission: "settings.edge.manage"}
    )
  end

  attributes do
    uuid_primary_key :id
    attribute :generation, :integer, allow_nil?: false, public?: true, constraints: [min: 1]
    attribute :fingerprint, :string, public?: true, constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :reason, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 1024]

    attribute :revoked_by, :string, allow_nil?: false, public?: true
    create_timestamp :revoked_at
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

  identities do
    identity :decision, [:component_id, :generation, :fingerprint], nils_distinct?: false
  end
end
