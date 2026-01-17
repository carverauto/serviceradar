defmodule ServiceRadar.Edge.Workers.ProvisionLeafWorker do
  @moduledoc """
  Oban worker for provisioning NATS leaf server certificates and configuration.

  When an EdgeSite is created, this worker:
  1. Loads the tenant's CA
  2. Generates leaf certificates (for upstream mTLS connection)
  3. Generates server certificates (for local client connections)
  4. Generates NATS configuration checksum
  5. Updates the NatsLeafServer with the provisioned data

  ## Certificate Types

  - **Leaf certificate**: CN = `leaf.{site_slug}.{tenant_slug}.serviceradar`
    Used for mTLS connection to the SaaS NATS cluster

  - **Server certificate**: CN = `nats-server.{site_slug}.{tenant_slug}.serviceradar`
    Used for local collector connections to the leaf
  """

  use Oban.Worker,
    queue: :edge,
    max_attempts: 3,
    priority: 1

  require Ash.Query
  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.{EdgeSite, NatsLeafServer, TenantCA}
  alias ServiceRadar.Oban.Router

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"leaf_server_id" => leaf_server_id}}) do
    Logger.info("Provisioning NATS leaf server: #{leaf_server_id}")

    # DB connection's search_path determines the schema
    with {:ok, leaf_server} <- load_leaf_server(leaf_server_id),
         {:ok, edge_site} <- load_edge_site(leaf_server.edge_site_id),
         {:ok, tenant} <- load_tenant(),
         {:ok, tenant_ca} <- get_tenant_ca(),
         {:ok, leaf_certs} <- generate_leaf_certificates(tenant_ca, tenant, edge_site),
         {:ok, server_certs} <- generate_server_certificates(tenant_ca, tenant, edge_site),
         {:ok, config_checksum} <- compute_config_checksum(leaf_server, leaf_certs, server_certs),
         {:ok, _updated} <-
           update_leaf_server(
             leaf_server,
             leaf_certs,
             server_certs,
             tenant_ca,
             config_checksum
           ) do
      Logger.info("Successfully provisioned NATS leaf server: #{leaf_server_id}")
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Failed to provision leaf server #{leaf_server_id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Enqueues a provisioning job for the given NatsLeafServer.
  """
  def enqueue(leaf_server_id, _opts \\ []) when is_binary(leaf_server_id) do
    %{"leaf_server_id" => leaf_server_id}
    |> __MODULE__.new()
    |> Router.insert()
  end

  # Private functions

  defp load_leaf_server(leaf_server_id) do
    # Simple actor - DB connection's search_path determines the schema
    actor = SystemActor.system(:provision_leaf)

    case Ash.get(NatsLeafServer, leaf_server_id, actor: actor) do
      {:ok, nil} -> {:error, :leaf_server_not_found}
      {:ok, server} -> {:ok, server}
      {:error, error} -> {:error, error}
    end
  end

  defp load_edge_site(edge_site_id) do
    # Simple actor - DB connection's search_path determines the schema
    actor = SystemActor.system(:provision_leaf)

    case Ash.get(EdgeSite, edge_site_id, actor: actor) do
      {:ok, nil} -> {:error, :edge_site_not_found}
      {:ok, site} -> {:ok, site}
      {:error, error} -> {:error, error}
    end
  end

  defp load_tenant do
    # DB connection's search_path determines the schema - get the single tenant
    actor = SystemActor.system(:provision_leaf)

    case ServiceRadar.Identity.Tenant
         |> Ash.Query.for_read(:read)
         |> Ash.Query.limit(1)
         |> Ash.read_one(actor: actor) do
      {:ok, nil} -> {:error, :tenant_not_found}
      {:ok, tenant} -> {:ok, tenant}
      {:error, error} -> {:error, error}
    end
  end

  defp get_tenant_ca do
    # In the single-tenant-per-deployment architecture, certificate generation
    # is handled by external infrastructure (SPIFFE/SPIRE, cert-manager, etc.)
    # TenantCA resource has been removed.
    {:error, :tenant_ca_not_available}
  end

  defp generate_leaf_certificates(tenant_ca, tenant, edge_site) do
    # Decrypt tenant CA private key
    case ServiceRadar.Vault.decrypt(tenant_ca.private_key_pem) do
      {:ok, private_key_pem} ->
        ca_data = %{
          tenant_slug: tenant.slug,
          certificate_pem: tenant_ca.certificate_pem,
          private_key_pem: private_key_pem
        }

        # CN format: leaf.{site_slug}.{tenant_slug}.serviceradar
        component_id = "leaf.#{edge_site.slug}"

        TenantCA.Generator.generate_component_cert(
          ca_data,
          component_id,
          :nats_leaf,
          tenant.slug,
          validity_days: 365,
          dns_names: [
            "leaf.#{edge_site.slug}.#{tenant.slug}.serviceradar",
            "nats-leaf.#{edge_site.slug}.local"
          ]
        )

      {:error, reason} ->
        {:error, {:decrypt_failed, reason}}
    end
  end

  defp generate_server_certificates(tenant_ca, tenant, edge_site) do
    # Decrypt tenant CA private key
    case ServiceRadar.Vault.decrypt(tenant_ca.private_key_pem) do
      {:ok, private_key_pem} ->
        ca_data = %{
          tenant_slug: tenant.slug,
          certificate_pem: tenant_ca.certificate_pem,
          private_key_pem: private_key_pem
        }

        # CN format: nats-server.{site_slug}.{tenant_slug}.serviceradar
        component_id = "nats-server.#{edge_site.slug}"

        TenantCA.Generator.generate_component_cert(
          ca_data,
          component_id,
          :nats_server,
          tenant.slug,
          validity_days: 365,
          dns_names: [
            "nats-server.#{edge_site.slug}.#{tenant.slug}.serviceradar",
            "nats.#{edge_site.slug}.local",
            "localhost"
          ]
        )

      {:error, reason} ->
        {:error, {:decrypt_failed, reason}}
    end
  end

  defp compute_config_checksum(leaf_server, leaf_certs, server_certs) do
    # Compute checksum of configuration-relevant data
    data =
      :erlang.term_to_binary(%{
        upstream_url: leaf_server.upstream_url,
        local_listen: leaf_server.local_listen,
        leaf_cert_serial: leaf_certs.serial_number,
        server_cert_serial: server_certs.serial_number
      })

    checksum = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
    {:ok, checksum}
  end

  defp update_leaf_server(
         leaf_server,
         leaf_certs,
         server_certs,
         tenant_ca,
         config_checksum
       ) do
    # Simple actor - DB connection's search_path determines the schema
    actor = SystemActor.system(:provision_leaf)

    leaf_server
    |> Ash.Changeset.for_update(:provision, %{
      leaf_cert_pem: leaf_certs.certificate_pem,
      leaf_key_pem: leaf_certs.private_key_pem,
      server_cert_pem: server_certs.certificate_pem,
      server_key_pem: server_certs.private_key_pem,
      ca_chain_pem: tenant_ca.certificate_pem,
      config_checksum: config_checksum
    }, actor: actor)
    |> Ash.update()
  end
end
