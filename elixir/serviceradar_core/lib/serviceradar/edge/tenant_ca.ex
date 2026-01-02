defmodule ServiceRadar.Edge.TenantCA do
  @moduledoc """
  Per-tenant Certificate Authority for edge component isolation.

  Each tenant has its own intermediate CA signed by the platform root CA.
  Edge components (pollers, agents, checkers) receive certificates signed
  by their tenant's CA, ensuring:

  - Network-level isolation: Components can only connect to same-tenant services
  - Certificate-based authentication: Tenant ID is cryptographically verified
  - Revocation scope: Revoking a tenant CA invalidates all their edge certs

  ## Certificate Hierarchy

  ```
  Platform Root CA (long-lived, offline)
  ├── Tenant-A Intermediate CA
  │   ├── poller.partition-1.tenant-a.serviceradar
  │   └── agent-001.partition-1.tenant-a.serviceradar
  ├── Tenant-B Intermediate CA
  │   └── poller.partition-1.tenant-b.serviceradar
  └── Platform Services CA (shared infrastructure)
      └── core-elx.serviceradar
  ```

  ## Certificate CN Format

  Edge component certificates use the format:
  `<component-id>.<partition-id>.<tenant-slug>.serviceradar`

  This allows extracting tenant identity from the certificate CN.

  ## Security

  - CA private keys are encrypted at rest using AshCloak/Vault
  - CA certificates have a default validity of 10 years
  - Component certificates have a default validity of 1 year
  - Serial numbers are tracked to prevent reuse
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  postgres do
    table "tenant_cas"
    repo ServiceRadar.Repo

    identity_wheres_to_sql unique_active_tenant_ca: "status = 'active'"

    custom_indexes do
      index [:spki_sha256]
    end
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:private_key_pem])
    decrypt_by_default([])
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  actions do
    defaults [:read]

    read :active do
      description "Active tenant CAs"
      filter expr(status == :active)
    end

    read :by_tenant do
      argument :tenant_id, :uuid, allow_nil?: false
      filter expr(tenant_id == ^arg(:tenant_id))
    end

    read :by_spki do
      argument :spki_sha256, :string, allow_nil?: false
      filter expr(spki_sha256 == ^arg(:spki_sha256) and status == :active)
      prepare build(limit: 1)
    end

    create :create do
      description "Create a new tenant CA (internal use)"
      accept [
        :tenant_id,
        :certificate_pem,
        :private_key_pem,
        :spki_sha256,
        :serial_number,
        :not_before,
        :not_after,
        :subject_cn
      ]
    end

    create :generate do
      description """
      Generate a new intermediate CA for a tenant.

      Signs the CA certificate using the platform root CA.
      """

      argument :tenant_id, :uuid do
        allow_nil? false
        description "Tenant to generate CA for"
      end

      argument :validity_years, :integer do
        default 10
        description "CA certificate validity in years"
      end

      change fn changeset, _context ->
        tenant_id = Ash.Changeset.get_argument(changeset, :tenant_id)
        validity_years = Ash.Changeset.get_argument(changeset, :validity_years)

        case ServiceRadar.Edge.TenantCA.Generator.generate_tenant_ca(
               tenant_id,
               validity_years
             ) do
          {:ok, ca_data} ->
            changeset
            |> Ash.Changeset.force_change_attribute(:tenant_id, tenant_id)
            |> Ash.Changeset.force_change_attribute(:certificate_pem, ca_data.certificate_pem)
            |> Ash.Changeset.force_change_attribute(:private_key_pem, ca_data.private_key_pem)
            |> Ash.Changeset.force_change_attribute(:spki_sha256, ca_data.spki_sha256)
            |> Ash.Changeset.force_change_attribute(:serial_number, ca_data.serial_number)
            |> Ash.Changeset.force_change_attribute(:not_before, ca_data.not_before)
            |> Ash.Changeset.force_change_attribute(:not_after, ca_data.not_after)
            |> Ash.Changeset.force_change_attribute(:subject_cn, ca_data.subject_cn)
            |> Ash.Changeset.force_change_attribute(:status, :active)

          {:error, reason} ->
            Ash.Changeset.add_error(changeset, field: :tenant_id, message: "CA generation failed: #{inspect(reason)}")
        end
      end
    end

    update :revoke do
      description "Revoke a tenant CA (invalidates all edge certs)"
      require_atomic? false
      argument :reason, :string

      change set_attribute(:status, :revoked)
      change set_attribute(:revoked_at, &DateTime.utc_now/0)

      change fn changeset, _context ->
        reason = Ash.Changeset.get_argument(changeset, :reason) || "Manual revocation"
        Ash.Changeset.force_change_attribute(changeset, :revocation_reason, reason)
      end
    end

    update :increment_serial do
      description "Increment the next serial number for child certificates"
      require_atomic? false

      change fn changeset, _context ->
        current = Ash.Changeset.get_data(changeset).next_child_serial
        Ash.Changeset.force_change_attribute(changeset, :next_child_serial, current + 1)
      end
    end
  end

  policies do
    # Super admins can do anything
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # Tenant admins can read their tenant's CA (cert only, not private key)
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Only super_admins can generate or revoke CAs
    policy action([:generate, :revoke]) do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # Internal actions (no actor check needed for system operations)
    policy action(:increment_serial) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this CA belongs to"
    end

    attribute :certificate_pem, :string do
      allow_nil? false
      public? true
      description "PEM-encoded CA certificate"
    end

    attribute :private_key_pem, :string do
      allow_nil? false
      sensitive? true
      public? false
      description "PEM-encoded CA private key (encrypted)"
    end

    attribute :serial_number, :string do
      allow_nil? false
      public? true
      description "CA certificate serial number"
    end

    attribute :spki_sha256, :string do
      allow_nil? true
      public? false
      description "SHA-256 SPKI hash of the CA public key"
    end

    attribute :next_child_serial, :integer do
      default 1
      public? false
      description "Next serial number for child certificates"
    end

    attribute :subject_cn, :string do
      allow_nil? false
      public? true
      description "CA certificate subject CN"
    end

    attribute :not_before, :utc_datetime do
      allow_nil? false
      public? true
      description "Certificate validity start"
    end

    attribute :not_after, :utc_datetime do
      allow_nil? false
      public? true
      description "Certificate validity end"
    end

    attribute :status, :atom do
      allow_nil? false
      default :active
      public? true
      constraints one_of: [:active, :revoked, :expired]
      description "CA status"
    end

    attribute :revoked_at, :utc_datetime do
      public? true
      description "When the CA was revoked"
    end

    attribute :revocation_reason, :string do
      public? true
      description "Reason for revocation"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :tenant, ServiceRadar.Identity.Tenant do
      source_attribute :tenant_id
      public? true
    end
  end

  calculations do
    calculate :is_valid, :boolean, expr(
      status == :active and
      not_before <= now() and
      not_after > now()
    )

    calculate :days_until_expiry, :integer, expr(
      fragment("EXTRACT(DAY FROM ? - NOW())", not_after)
    )
  end

  identities do
    identity :unique_active_tenant_ca, [:tenant_id, :status] do
      # Only allow one active CA per tenant
      where expr(status == :active)
    end
  end
end
