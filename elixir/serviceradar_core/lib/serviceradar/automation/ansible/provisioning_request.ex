defmodule ServiceRadar.Automation.Ansible.ProvisioningRequest do
  @moduledoc """
  Internal immutable receipt for a configuration API create request.

  No request body or credential material is retained. A per-request random
  comparison key is encrypted by the platform vault; the keyed request MAC is
  private and cannot be used to guess low-entropy input without that key.
  Resource reads and all user authorization remain with the owning service.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("ansible_provisioning_requests")
    schema("platform")
    repo(ServiceRadar.Repo)
    # The migration also enforces fixed MAC/identity lengths. Receipts have a
    # polymorphic resource ID, deliberately without a cascading foreign key:
    # deleting a resource must not make an old create request recreate it.
    migrate?(false)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:id, :initiator_id, :operation, :key_ciphertext, :request_mac, :resource_id])
    end
  end

  policies do
    import ServiceRadar.Policies
    system_bypass()
  end

  attributes do
    attribute :id, :string do
      primary_key?(true)
      allow_nil?(false)
      constraints(min_length: 64, max_length: 64)
    end

    attribute(:initiator_id, :uuid, allow_nil?: false)
    attribute(:operation, :string, allow_nil?: false)
    attribute(:key_ciphertext, :binary, allow_nil?: false, sensitive?: true)
    attribute(:request_mac, :binary, allow_nil?: false, sensitive?: true)
    attribute(:resource_id, :uuid, allow_nil?: false)
    create_timestamp(:inserted_at)
  end
end
