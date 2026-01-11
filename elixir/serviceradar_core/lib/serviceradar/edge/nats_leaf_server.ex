defmodule ServiceRadar.Edge.NatsLeafServer do
  @moduledoc """
  Tracks a NATS leaf server deployment for an edge site.

  Each EdgeSite has one NatsLeafServer that manages:
  - mTLS certificates for upstream (leaf -> SaaS) connection
  - Server certificates for local (collector -> leaf) connections
  - Configuration generation and checksum tracking

  ## Certificate Types

  - **Leaf certificate**: Used for mTLS connection to SaaS NATS cluster
    - CN: `leaf.{site_slug}.{tenant_slug}.serviceradar`
    - Signed by tenant CA

  - **Server certificate**: Used for local client (collector) connections
    - CN: `nats-server.{site_slug}.{tenant_slug}.serviceradar`
    - Signed by tenant CA

  ## State Machine

  - `pending` - Server created, waiting for certificate provisioning
  - `provisioned` - Certificates generated, ready for deployment
  - `connected` - Leaf has connected to SaaS cluster
  - `disconnected` - Leaf has lost connection to SaaS cluster

  ## Configuration

  The generated NATS leaf config follows `packaging/nats/config/nats-leaf.conf`:
  - JetStream enabled with domain "edge"
  - mTLS for upstream connection
  - Tenant NATS account credentials
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshCloak]

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Edge.EdgeSite

  postgres do
    table "nats_leaf_servers"
    repo ServiceRadar.Repo
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:leaf_key_pem_ciphertext, :server_key_pem_ciphertext])
    decrypt_by_default([])
  end

  state_machine do
    initial_states [:pending]
    default_initial_state :pending
    state_attribute :status

    transitions do
      transition :provision, from: :pending, to: :provisioned
      transition :connect, from: [:provisioned, :disconnected], to: :connected
      transition :disconnect, from: :connected, to: :disconnected
      transition :reprovision, from: [:provisioned, :connected, :disconnected], to: :pending
    end
  end

  multitenancy do
    strategy :context
  end

  actions do
    defaults [:read]

    read :by_edge_site do
      description "Find NATS leaf server by edge site"
      argument :edge_site_id, :uuid, allow_nil?: false
      get? true
      filter expr(edge_site_id == ^arg(:edge_site_id))
    end

    create :create do
      description "Create NATS leaf server for an edge site"
      accept [:edge_site_id, :tenant_id, :upstream_url, :local_listen]

      # Trigger provisioning after creation
      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, leaf_server ->
          # Enqueue async provisioning
          case TenantSchemas.schema_for_id(leaf_server.tenant_id) do
            nil ->
              {:error, :tenant_schema_not_found}

            tenant_schema ->
              case ServiceRadar.Edge.Workers.ProvisionLeafWorker.enqueue(leaf_server.id,
                     tenant_schema: tenant_schema
                   ) do
                {:ok, _job} -> {:ok, leaf_server}
                {:error, reason} -> {:error, reason}
              end
          end
        end)
      end
    end

    update :provision do
      description "Mark server as provisioned with certificates"
      # Non-atomic: encrypts keys and parses certificate expiry
      require_atomic? false
      accept []

      argument :leaf_cert_pem, :string, allow_nil?: false, sensitive?: true
      argument :leaf_key_pem, :string, allow_nil?: false, sensitive?: true
      argument :server_cert_pem, :string, allow_nil?: false, sensitive?: true
      argument :server_key_pem, :string, allow_nil?: false, sensitive?: true
      argument :ca_chain_pem, :string, allow_nil?: false, sensitive?: true
      argument :config_checksum, :string, allow_nil?: false

      change fn changeset, _context ->
        leaf_key_pem = Ash.Changeset.get_argument(changeset, :leaf_key_pem)
        server_key_pem = Ash.Changeset.get_argument(changeset, :server_key_pem)

        changeset
        |> Ash.Changeset.change_attribute(:leaf_cert_pem, Ash.Changeset.get_argument(changeset, :leaf_cert_pem))
        |> Ash.Changeset.change_attribute(:server_cert_pem, Ash.Changeset.get_argument(changeset, :server_cert_pem))
        |> Ash.Changeset.change_attribute(:ca_chain_pem, Ash.Changeset.get_argument(changeset, :ca_chain_pem))
        |> Ash.Changeset.change_attribute(:config_checksum, Ash.Changeset.get_argument(changeset, :config_checksum))
        |> Ash.Changeset.change_attribute(:provisioned_at, DateTime.utc_now())
        |> AshCloak.encrypt_and_set(:leaf_key_pem_ciphertext, leaf_key_pem)
        |> AshCloak.encrypt_and_set(:server_key_pem_ciphertext, server_key_pem)
        |> compute_cert_expiry()
      end
    end

    update :connect do
      description "Mark server as connected to SaaS"
      # Non-atomic: updates parent EdgeSite via after_action
      require_atomic? false
      accept []

      change set_attribute(:connected_at, &DateTime.utc_now/0)

      # Also update the parent EdgeSite status
      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, leaf_server ->
          update_edge_site_status(leaf_server, :active)
          {:ok, leaf_server}
        end)
      end
    end

    update :disconnect do
      description "Mark server as disconnected from SaaS"
      # Non-atomic: updates parent EdgeSite via after_action
      require_atomic? false
      accept []

      change set_attribute(:disconnected_at, &DateTime.utc_now/0)

      # Also update the parent EdgeSite status
      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, leaf_server ->
          update_edge_site_status(leaf_server, :offline)
          {:ok, leaf_server}
        end)
      end
    end

    update :reprovision do
      description "Request re-provisioning of certificates"
      # Non-atomic: enqueues Oban job via after_action
      require_atomic? false
      accept []

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, leaf_server ->
          # Enqueue provisioning job
          case TenantSchemas.schema_for_id(leaf_server.tenant_id) do
            nil ->
              {:error, :tenant_schema_not_found}

            tenant_schema ->
              case ServiceRadar.Edge.Workers.ProvisionLeafWorker.enqueue(leaf_server.id,
                     tenant_schema: tenant_schema
                   ) do
                {:ok, _job} -> {:ok, leaf_server}
                {:error, reason} -> {:error, reason}
              end
          end
        end)
      end
    end
  end

  policies do
    # Super admins can manage all servers
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # Tenant admins can read their tenant's servers
    policy action_type(:read) do
      authorize_if expr(tenant_id == ^actor(:tenant_id))
    end

    # Create is done internally
    policy action_type(:create) do
      authorize_if always()
    end

    # Status updates are internal
    policy action([:provision, :connect, :disconnect]) do
      authorize_if always()
    end

    # Reprovision requires tenant admin
    policy action(:reprovision) do
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
      description "Tenant this server belongs to"
    end

    attribute :edge_site_id, :uuid do
      allow_nil? false
      public? false
      description "Edge site this server belongs to"
    end

    attribute :status, :atom do
      allow_nil? false
      default :pending
      public? true
      constraints one_of: [:pending, :provisioned, :connected, :disconnected]
      description "Current operational status"
    end

    attribute :upstream_url, :string do
      allow_nil? false
      public? true
      description "SaaS NATS URL for leaf connection (e.g., 'tls://nats.serviceradar.cloud:7422')"
    end

    attribute :local_listen, :string do
      allow_nil? false
      default "0.0.0.0:4222"
      public? true
      description "Local listen address for collectors"
    end

    # Leaf certificates (for upstream mTLS connection)
    attribute :leaf_cert_pem, :string do
      allow_nil? true
      public? false
      description "PEM-encoded leaf certificate for upstream connection"
    end

    attribute :leaf_key_pem_ciphertext, :binary do
      allow_nil? true
      public? false
      sensitive? true
      description "Encrypted PEM-encoded leaf private key"
    end

    # Server certificates (for local client connections)
    attribute :server_cert_pem, :string do
      allow_nil? true
      public? false
      description "PEM-encoded server certificate for local clients"
    end

    attribute :server_key_pem_ciphertext, :binary do
      allow_nil? true
      public? false
      sensitive? true
      description "Encrypted PEM-encoded server private key"
    end

    # CA chain (tenant CA + root CA)
    attribute :ca_chain_pem, :string do
      allow_nil? true
      public? false
      description "PEM-encoded CA certificate chain"
    end

    # Configuration tracking
    attribute :config_checksum, :string do
      allow_nil? true
      public? false
      description "SHA256 checksum of generated config for drift detection"
    end

    attribute :cert_expires_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When the leaf certificate expires"
    end

    # Timestamps
    attribute :provisioned_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When certificates were provisioned"
    end

    attribute :connected_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "Last time leaf connected to SaaS"
    end

    attribute :disconnected_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "Last time leaf disconnected from SaaS"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :tenant, ServiceRadar.Identity.Tenant do
      source_attribute :tenant_id
      allow_nil? false
    end

    belongs_to :edge_site, ServiceRadar.Edge.EdgeSite do
      source_attribute :edge_site_id
      allow_nil? false
    end
  end

  identities do
    identity :unique_per_edge_site, [:edge_site_id]
  end

  calculations do
    calculate :cert_expiring_soon?,
              :boolean,
              expr(
                not is_nil(cert_expires_at) and
                  cert_expires_at < datetime_add(now(), 30, :day)
              )
  end

  # Helper to compute certificate expiry from PEM
  defp compute_cert_expiry(changeset) do
    case Ash.Changeset.get_argument(changeset, :leaf_cert_pem) do
      nil ->
        changeset

      cert_pem ->
        case parse_cert_expiry(cert_pem) do
          {:ok, expires_at} ->
            Ash.Changeset.change_attribute(changeset, :cert_expires_at, expires_at)

          _ ->
            changeset
        end
    end
  end

  defp parse_cert_expiry(cert_pem) do
    try do
      [pem_entry | _] = :public_key.pem_decode(cert_pem)
      cert = :public_key.pem_entry_decode(pem_entry)

      # Extract notAfter from certificate
      {:Certificate, {:TBSCertificate, _, _, _, _, {:Validity, _not_before, not_after}, _, _, _, _, _}, _, _} = cert

      case not_after do
        {:utcTime, time_str} ->
          parse_utc_time(time_str)

        {:generalTime, time_str} ->
          parse_general_time(time_str)
      end
    rescue
      _ -> {:error, :parse_failed}
    end
  end

  defp parse_utc_time(time_str) do
    # Format: YYMMDDHHMMSSZ
    time_str = to_string(time_str)

    with {year, rest} <- String.split_at(time_str, 2),
         {month, rest} <- String.split_at(rest, 2),
         {day, rest} <- String.split_at(rest, 2),
         {hour, rest} <- String.split_at(rest, 2),
         {minute, rest} <- String.split_at(rest, 2),
         {second, "Z"} <- String.split_at(rest, 2) do
      # Y2K handling: years 00-49 are 20XX, 50-99 are 19XX
      year_int = String.to_integer(year)
      full_year = if year_int < 50, do: 2000 + year_int, else: 1900 + year_int

      {:ok, datetime} =
        DateTime.new(
          Date.new!(full_year, String.to_integer(month), String.to_integer(day)),
          Time.new!(String.to_integer(hour), String.to_integer(minute), String.to_integer(second)),
          "Etc/UTC"
        )

      {:ok, datetime}
    else
      _ -> {:error, :invalid_format}
    end
  end

  defp parse_general_time(time_str) do
    # Format: YYYYMMDDHHMMSSZ
    time_str = to_string(time_str)

    with {year, rest} <- String.split_at(time_str, 4),
         {month, rest} <- String.split_at(rest, 2),
         {day, rest} <- String.split_at(rest, 2),
         {hour, rest} <- String.split_at(rest, 2),
         {minute, rest} <- String.split_at(rest, 2),
         {second, "Z"} <- String.split_at(rest, 2) do
      {:ok, datetime} =
        DateTime.new(
          Date.new!(String.to_integer(year), String.to_integer(month), String.to_integer(day)),
          Time.new!(String.to_integer(hour), String.to_integer(minute), String.to_integer(second)),
          "Etc/UTC"
        )

      {:ok, datetime}
    else
      _ -> {:error, :invalid_format}
    end
  end

  defp update_edge_site_status(leaf_server, new_status) do
    action =
      case new_status do
        :active -> :activate
        :offline -> :go_offline
      end

    case TenantSchemas.schema_for_id(leaf_server.tenant_id) do
      nil ->
        :ok

      tenant_schema ->
        case Ash.get(EdgeSite, leaf_server.edge_site_id, tenant: tenant_schema, authorize?: false) do
          {:ok, site} when site.status != new_status ->
            site
            |> Ash.Changeset.for_update(action, %{}, tenant: tenant_schema)
            |> Ash.update(authorize?: false)

          _ ->
            :ok
        end
    end
  end
end
