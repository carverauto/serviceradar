defmodule ServiceRadarWebNG.Edge.HubReadiness do
  @moduledoc """
  Assembles the hub certificate-authorization readiness object in web-ng.

  Core decides `enforcement_configured`, `authorizer_answering`,
  `authorizer_reason`, `signing_keys_provisioned`, `leaf_listener`, and
  `chart_identities`. Web-ng adds `leaf_upstream_url` by reading
  `:nats_leaf_upstream_url` from the application environment without a default
  so the hard-coded hosted fallback is never reported as configured.

  Served on both `GET /api/admin/managed-components/bootstrap` (for the CLI)
  and `GET /v1/hub/readiness` on the private control-plane listener (for the
  hosted control plane, issue #6940).
  """

  alias ServiceRadar.Cluster.ClusterRPC

  @doc """
  Fetches hub readiness from core and merges web-ng's `leaf_upstream_url` flag.
  """
  @spec fetch() :: {:ok, map()} | {:error, :core_unavailable}
  def fetch do
    case fetch_core() do
      {:ok, %{} = core_hub} ->
        {:ok, Map.put(core_hub, :leaf_upstream_url, leaf_upstream_url_configured?())}

      _ ->
        {:error, :core_unavailable}
    end
  end

  @doc """
  Returns true only when `:nats_leaf_upstream_url` is explicitly configured
  as a non-empty string in the `:serviceradar` application environment.
  """
  @spec leaf_upstream_url_configured?() :: boolean()
  def leaf_upstream_url_configured? do
    case Application.get_env(:serviceradar, :nats_leaf_upstream_url) do
      url when is_binary(url) -> String.trim(url) != ""
      _ -> false
    end
  end

  defp fetch_core do
    manager = ServiceRadar.NATS.ManagedCertificateAuthorization

    nodes = fn ->
      Enum.filter([Node.self() | Node.list()], fn node ->
        is_pid(:rpc.call(node, Process, :whereis, [manager], 2_000))
      end)
    end

    case ClusterRPC.call(nodes, ServiceRadar.NATS.HubReadiness, :status, [], timeout: 10_000) do
      {:ok, %{} = status} -> {:ok, status}
      _ -> {:error, :core_unavailable}
    end
  end
end
