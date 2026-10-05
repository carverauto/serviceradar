defmodule ServiceRadar.Edge.Workers.ProvisionLeafWorker do
  @moduledoc """
  Oban worker that provisions a NATS leaf server for an edge site.

  It issues the leaf client certificate (for the upstream leafnode connection
  to the hub) and the local server certificate (for collectors at the site)
  from the agent-gateway CA via `ServiceRadar.Edge.NatsLeafCertificateIssuer`,
  then records them, the encrypted keys, the CA chain and a config checksum
  through the `NatsLeafServer` `:provision` action.

  A leaf server that is no longer `pending` is left alone. When no gateway is
  reachable the job returns an error so Oban retries with backoff.
  """

  use Oban.Worker,
    queue: :edge,
    max_attempts: 10,
    priority: 1

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.EdgeSite
  alias ServiceRadar.Edge.NatsLeafCertificateIssuer
  alias ServiceRadar.Edge.NatsLeafServer
  alias ServiceRadar.Oban.Router

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{} = job), do: perform(job, [])

  @doc """
  `perform/1` with injectable collaborators. `:certificate_issuer` is a module
  exporting `issue/1` (default `ServiceRadar.Edge.NatsLeafCertificateIssuer`),
  mirroring the `:account_client` seam in `ProvisionAgentWorker`.
  """
  def perform(%Oban.Job{args: %{"leaf_server_id" => leaf_server_id}}, opts) do
    certificate_issuer = Keyword.get(opts, :certificate_issuer, NatsLeafCertificateIssuer)
    Logger.info("Provisioning NATS leaf server: #{leaf_server_id}")

    with {:ok, leaf_server} <- load_leaf_server(leaf_server_id),
         :ok <- ensure_pending(leaf_server),
         {:ok, edge_site} <- load_edge_site(leaf_server.edge_site_id),
         {:ok, material} <- certificate_issuer.issue(edge_site),
         {:ok, config_checksum} <- compute_config_checksum(leaf_server, edge_site),
         {:ok, _updated} <- update_leaf_server(leaf_server, material, config_checksum) do
      Logger.info("Successfully provisioned NATS leaf server: #{leaf_server_id}")
      :ok
    else
      {:skip, status} ->
        Logger.info("NATS leaf server #{leaf_server_id} is #{status}; nothing to provision")
        :ok

      {:error, :leaf_server_not_found} ->
        {:cancel, :leaf_server_not_found}

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

  defp ensure_pending(%{status: :pending}), do: :ok
  defp ensure_pending(%{status: status}), do: {:skip, status}

  defp load_leaf_server(leaf_server_id) do
    actor = SystemActor.system(:provision_leaf)

    case Ash.get(NatsLeafServer, leaf_server_id, actor: actor, not_found_error?: false) do
      {:ok, nil} -> {:error, :leaf_server_not_found}
      {:ok, server} -> {:ok, server}
      {:error, error} -> {:error, error}
    end
  end

  defp load_edge_site(edge_site_id) do
    actor = SystemActor.system(:provision_leaf)

    case Ash.get(EdgeSite, edge_site_id, actor: actor) do
      {:ok, nil} -> {:error, :edge_site_not_found}
      {:ok, site} -> {:ok, site}
      {:error, error} -> {:error, error}
    end
  end

  defp compute_config_checksum(leaf_server, edge_site) do
    # Compute checksum of configuration-relevant data
    # In single-deployment mode, we just track the basic config
    data =
      :erlang.term_to_binary(%{
        upstream_url: leaf_server.upstream_url,
        local_listen: leaf_server.local_listen,
        edge_site_slug: edge_site.slug
      })

    checksum = :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)
    {:ok, checksum}
  end

  defp update_leaf_server(leaf_server, material, config_checksum) do
    actor = SystemActor.system(:provision_leaf)

    leaf_server
    |> Ash.Changeset.for_update(
      :provision,
      %{
        leaf_cert_pem: material.leaf_cert_pem,
        leaf_key_pem: material.leaf_key_pem,
        server_cert_pem: material.server_cert_pem,
        server_key_pem: material.server_key_pem,
        ca_chain_pem: material.ca_chain_pem,
        config_checksum: config_checksum
      },
      actor: actor
    )
    |> Ash.update()
  end
end
