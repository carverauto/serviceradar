defmodule ServiceRadar.Edge.Workers.ProvisionLeafWorker do
  @moduledoc """
  Oban worker for provisioning NATS leaf server configuration.

  In single-tenant-per-deployment mode:
  - Certificate generation is handled by external infrastructure (SPIFFE/SPIRE, cert-manager)
  - The worker updates the NatsLeafServer record with a config checksum

  When an EdgeSite is created, this worker validates the configuration
  and updates the NatsLeafServer status.
  """

  use Oban.Worker,
    queue: :edge,
    max_attempts: 3,
    priority: 1

  require Ash.Query
  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.{EdgeSite, NatsLeafServer}
  alias ServiceRadar.Oban.Router

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"leaf_server_id" => leaf_server_id}}) do
    Logger.info("Provisioning NATS leaf server: #{leaf_server_id}")

    # In single-tenant mode, certificate generation is handled by external infrastructure
    with {:ok, leaf_server} <- load_leaf_server(leaf_server_id),
         {:ok, edge_site} <- load_edge_site(leaf_server.edge_site_id),
         {:ok, config_checksum} <- compute_config_checksum(leaf_server, edge_site),
         {:ok, _updated} <- update_leaf_server(leaf_server, config_checksum) do
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
    actor = SystemActor.system(:provision_leaf)

    case Ash.get(NatsLeafServer, leaf_server_id, actor: actor) do
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
    # In single-tenant mode, we just track the basic config
    data =
      :erlang.term_to_binary(%{
        upstream_url: leaf_server.upstream_url,
        local_listen: leaf_server.local_listen,
        edge_site_slug: edge_site.slug
      })

    checksum = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
    {:ok, checksum}
  end

  defp update_leaf_server(leaf_server, config_checksum) do
    # In single-tenant mode, TLS certificates are provisioned by external infrastructure
    # We only update the config checksum to indicate the leaf server is ready
    actor = SystemActor.system(:provision_leaf)

    leaf_server
    |> Ash.Changeset.for_update(:provision, %{
      config_checksum: config_checksum
    }, actor: actor)
    |> Ash.update()
  end
end
