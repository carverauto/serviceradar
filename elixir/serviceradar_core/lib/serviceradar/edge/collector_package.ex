defmodule ServiceRadar.Edge.CollectorPackage do
  @moduledoc """
  Collector-specific deployment package for edge collectors with NATS credentials.

  This resource manages deployment packages for collectors (flowgger, trapd,
  netflow, otel) that include NATS credentials for event streaming.

  ## Collector Types

  - `:flowgger` - Syslog collector (RFC 5424, RFC 3164)
  - `:trapd` - SNMP trap collector (v1, v2c, v3)
  - `:netflow` - NetFlow/sFlow/IPFIX collector
  - `:otel` - OpenTelemetry collector (traces, metrics, logs)

  ## Package Lifecycle

  1. Admin creates collector package (triggers credential provisioning)
  2. Oban worker provisions NATS credentials via datasvc
  3. Package becomes ready for download
  4. Collector downloads and installs package
  5. Package marked as installed on successful activation

  ## Package Contents

  - NATS credentials file (.creds)
  - Collector configuration (collector-specific)
  - mTLS certificates (from tenant CA)
  - Installation instructions
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshCloak]

  alias ServiceRadar.Cluster.TenantSchemas

  postgres do
    table "collector_packages"
    repo ServiceRadar.Repo
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:nats_creds_ciphertext, :tls_key_pem_ciphertext])
    # Not decrypted by default for security - use ServiceRadar.Vault.decrypt/1 when needed
    decrypt_by_default([])
  end

  state_machine do
    initial_states [:pending]
    default_initial_state :pending
    state_attribute :status

    transitions do
      transition :provision, from: :pending, to: :provisioning
      transition :ready, from: :provisioning, to: :ready
      transition :fail, from: [:pending, :provisioning], to: :failed
      transition :download, from: :ready, to: :downloaded
      transition :install, from: :downloaded, to: :installed
      transition :revoke, from: [:ready, :downloaded, :installed], to: :revoked
    end
  end

  multitenancy do
    strategy :context
  end

  actions do
    defaults [:read]

    read :active do
      description "Get active (non-revoked) packages"
      filter expr(status not in [:revoked, :failed])
    end

    read :ready_for_download do
      description "Get packages ready for download"
      filter expr(status == :ready)
    end

    read :by_collector_type do
      argument :collector_type, :atom, allow_nil?: false
      filter expr(collector_type == ^arg(:collector_type) and status not in [:revoked, :failed])
    end

    read :by_download_token do
      description "Find package by download token hash"
      argument :token_hash, :string, allow_nil?: false
      get? true
      filter expr(download_token_hash == ^arg(:token_hash) and status == :ready)
    end

    create :create do
      description "Create a new collector package (triggers async provisioning)"
      accept [:collector_type, :site, :hostname, :config_overrides, :edge_site_id]

      argument :user_name, :string do
        allow_nil? true
        description "Optional custom user name for NATS credentials"
      end

      argument :token_hash, :string do
        allow_nil? true
        sensitive? true
        description "Pre-computed token hash (for enrollment token integration)"
      end

      argument :token_expires_at, :utc_datetime_usec do
        allow_nil? true
        description "Token expiration time"
      end

      change fn changeset, _context ->
        collector_type = Ash.Changeset.get_attribute(changeset, :collector_type)
        site = Ash.Changeset.get_attribute(changeset, :site) || "default"

        # Generate user name if not provided
        user_name =
          case Ash.Changeset.get_argument(changeset, :user_name) do
            nil ->
              random_suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
              "#{collector_type}-#{site}-#{random_suffix}"

            name ->
              name
          end

        # Use provided token hash or generate new one
        {token_hash, token_expires_at} =
          case Ash.Changeset.get_argument(changeset, :token_hash) do
            nil ->
              # Generate new token (legacy behavior)
              token_bytes = :crypto.strong_rand_bytes(32)
              token_secret = Base.url_encode64(token_bytes, padding: false)
              hash = :crypto.hash(:sha256, token_secret) |> Base.encode16(case: :lower)
              expires = DateTime.add(DateTime.utc_now(), 7, :day)
              {hash, expires}

            provided_hash ->
              # Use provided token hash (from EnrollmentToken)
              expires =
                Ash.Changeset.get_argument(changeset, :token_expires_at) ||
                  DateTime.add(DateTime.utc_now(), 1, :day)

              {provided_hash, expires}
          end

        changeset
        |> Ash.Changeset.change_attribute(:user_name, user_name)
        |> Ash.Changeset.change_attribute(:download_token_hash, token_hash)
        |> Ash.Changeset.change_attribute(:download_token_expires_at, token_expires_at)
      end

      change fn changeset, _context ->
        # Enqueue provisioning job and broadcast after creation
        Ash.Changeset.after_action(changeset, fn _changeset, package ->
          # Broadcast creation event
          __MODULE__.broadcast_created(package)

          # Enqueue async provisioning
          case TenantSchemas.schema_for_id(package.tenant_id) do
            nil ->
              {:error, :tenant_schema_not_found}

            tenant_schema ->
              case ServiceRadar.Edge.Workers.ProvisionCollectorWorker.enqueue(package.id,
                     tenant_schema: tenant_schema
                   ) do
                {:ok, _job} -> {:ok, package}
                {:error, reason} -> {:error, reason}
              end
          end
        end)
      end
    end

    update :provision do
      description "Mark package as provisioning"
      accept []
      require_atomic? false
    end

    update :ready do
      description "Mark package as ready after successful provisioning"
      accept []
      require_atomic? false

      argument :nats_credential_id, :uuid, allow_nil?: false
      argument :nats_creds_content, :string, allow_nil?: false, sensitive?: true
      argument :tls_cert_pem, :string, allow_nil?: false, sensitive?: true
      argument :tls_key_pem, :string, allow_nil?: false, sensitive?: true
      argument :ca_chain_pem, :string, allow_nil?: false, sensitive?: true

      change fn changeset, _context ->
        old_status = Ash.Changeset.get_data(changeset, :status)
        creds_content = Ash.Changeset.get_argument(changeset, :nats_creds_content)
        tls_key_pem = Ash.Changeset.get_argument(changeset, :tls_key_pem)

        changeset
        |> Ash.Changeset.change_attribute(
          :nats_credential_id,
          Ash.Changeset.get_argument(changeset, :nats_credential_id)
        )
        # Store TLS certificate (public - not encrypted)
        |> Ash.Changeset.change_attribute(:tls_cert_pem, Ash.Changeset.get_argument(changeset, :tls_cert_pem))
        |> Ash.Changeset.change_attribute(:ca_chain_pem, Ash.Changeset.get_argument(changeset, :ca_chain_pem))
        # Encrypt NATS credentials and TLS private key using AshCloak
        |> AshCloak.encrypt_and_set(:nats_creds_ciphertext, creds_content)
        |> AshCloak.encrypt_and_set(:tls_key_pem_ciphertext, tls_key_pem)
        |> Ash.Changeset.after_action(fn _changeset, package ->
          __MODULE__.broadcast_status_changed(package, old_status, :ready)
          {:ok, package}
        end)
      end
    end

    update :fail do
      description "Mark package as failed"
      accept []
      require_atomic? false

      argument :error_message, :string

      change fn changeset, _context ->
        old_status = Ash.Changeset.get_data(changeset, :status)

        changeset
        |> Ash.Changeset.change_attribute(
          :error_message,
          Ash.Changeset.get_argument(changeset, :error_message)
        )
        |> Ash.Changeset.after_action(fn _changeset, package ->
          __MODULE__.broadcast_status_changed(package, old_status, :failed)
          {:ok, package}
        end)
      end
    end

    update :download do
      description "Mark package as downloaded"
      accept []
      require_atomic? false

      argument :downloaded_by_ip, :string

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.change_attribute(:downloaded_at, DateTime.utc_now())
        |> Ash.Changeset.change_attribute(:downloaded_by_ip, Ash.Changeset.get_argument(changeset, :downloaded_by_ip))
      end
    end

    update :install do
      description "Mark package as installed"
      accept []
      require_atomic? false

      change set_attribute(:installed_at, &DateTime.utc_now/0)
    end

    update :revoke do
      description "Revoke a package (also revokes associated NATS credential)"
      accept []
      require_atomic? false

      argument :reason, :string

      change fn changeset, _context ->
        old_status = Ash.Changeset.get_data(changeset, :status)

        changeset
        |> Ash.Changeset.change_attribute(:revoked_at, DateTime.utc_now())
        |> Ash.Changeset.change_attribute(:revoke_reason, Ash.Changeset.get_argument(changeset, :reason))
        |> Ash.Changeset.put_context(:old_status, old_status)
      end

      # After revoking the package, revoke the NATS credential and broadcast
      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn changeset, package ->
          # Revoke associated NATS credential
          if package.nats_credential_id do
            case Ash.get(ServiceRadar.Edge.NatsCredential, package.nats_credential_id,
                   tenant: TenantSchemas.schema_for_tenant(package.tenant_id),
                   authorize?: false
                 ) do
              {:ok, credential} when not is_nil(credential) ->
                credential
                |> Ash.Changeset.for_update(:revoke, %{reason: "Package revoked"},
                  tenant: TenantSchemas.schema_for_tenant(package.tenant_id)
                )
                |> Ash.update(authorize?: false)

              _ ->
                :ok
            end
          end

          # Broadcast status change
          old_status = changeset.context[:old_status] || :unknown
          __MODULE__.broadcast_status_changed(package, old_status, :revoked)

          {:ok, package}
        end)
      end
    end
  end

  policies do
    # Super admins can manage all packages
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # Tenant admins can manage their tenant's packages
    policy action_type(:read) do
      authorize_if expr(tenant_id == ^actor(:tenant_id))
    end

    policy action_type(:create) do
      authorize_if expr(^actor(:role) == :admin and tenant_id == ^actor(:tenant_id))
    end

    policy action(:revoke) do
      authorize_if expr(^actor(:role) == :admin and tenant_id == ^actor(:tenant_id))
    end
  end

  changes do
    change ServiceRadar.Changes.AssignTenantId
  end

  attributes do
    uuid_primary_key :id

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this package belongs to"
    end

    attribute :collector_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:flowgger, :trapd, :netflow, :otel]
      description "Type of collector"
    end

    attribute :user_name, :string do
      allow_nil? false
      public? true
      description "NATS user name for credentials"
    end

    attribute :site, :string do
      allow_nil? true
      default "default"
      public? true
      description "Site/location identifier"
    end

    attribute :hostname, :string do
      allow_nil? true
      public? true
      description "Target hostname for installation"
    end

    attribute :status, :atom do
      allow_nil? false
      default :pending
      public? true
      constraints one_of: [:pending, :provisioning, :ready, :downloaded, :installed, :revoked, :failed]
      description "Package status"
    end

    attribute :nats_credential_id, :uuid do
      allow_nil? true
      public? false
      description "Associated NATS credential"
    end

    attribute :download_token_hash, :string do
      allow_nil? true
      public? false
      description "SHA256 hash of download token"
    end

    attribute :download_token_expires_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When download token expires"
    end

    attribute :downloaded_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When package was downloaded"
    end

    attribute :downloaded_by_ip, :string do
      allow_nil? true
      public? false
      description "IP that downloaded the package"
    end

    attribute :installed_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When package was installed"
    end

    attribute :revoked_at, :utc_datetime_usec do
      allow_nil? true
      public? false
      description "When package was revoked"
    end

    attribute :revoke_reason, :string do
      allow_nil? true
      public? false
      description "Reason for revocation"
    end

    attribute :error_message, :string do
      allow_nil? true
      public? false
      description "Error message if provisioning failed"
    end

    attribute :nats_creds_ciphertext, :binary do
      allow_nil? true
      public? false
      sensitive? true
      description "Encrypted NATS user credentials (.creds file content)"
    end

    attribute :tls_cert_pem, :string do
      allow_nil? true
      public? false
      description "PEM-encoded TLS certificate for mTLS authentication"
    end

    attribute :tls_key_pem_ciphertext, :binary do
      allow_nil? true
      public? false
      sensitive? true
      description "Encrypted PEM-encoded TLS private key"
    end

    attribute :ca_chain_pem, :string do
      allow_nil? true
      public? false
      description "PEM-encoded CA certificate chain (tenant CA + root CA)"
    end

    attribute :config_overrides, :map do
      allow_nil? true
      default %{}
      public? false
      description "Collector-specific configuration overrides"
    end

    attribute :edge_site_id, :uuid do
      allow_nil? true
      public? true
      description "Optional edge site for local NATS connection"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :tenant, ServiceRadar.Identity.Tenant do
      source_attribute :tenant_id
      allow_nil? false
    end

    belongs_to :nats_credential, ServiceRadar.Edge.NatsCredential do
      source_attribute :nats_credential_id
      allow_nil? true
    end

    belongs_to :edge_site, ServiceRadar.Edge.EdgeSite do
      source_attribute :edge_site_id
      allow_nil? true
    end
  end

  calculations do
    calculate :is_downloadable?,
              :boolean,
              expr(
                status == :ready and
                  download_token_expires_at > ^DateTime.utc_now()
              )
  end

  identities do
    identity :unique_user_name_per_tenant, [:tenant_id, :user_name]
  end

  # PubSub broadcast helpers - delegates to ServiceRadar.Edge.PubSub

  @doc false
  def broadcast_created(package) do
    ServiceRadar.Edge.PubSub.broadcast_package_created(package)
  end

  @doc false
  def broadcast_status_changed(package, old_status, new_status) do
    ServiceRadar.Edge.PubSub.broadcast_package_status_changed(package, old_status, new_status)
  end
end
