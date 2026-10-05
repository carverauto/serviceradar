defmodule ServiceRadarWebNG.Edge.EdgeSiteBundles do
  @moduledoc """
  Builds the downloadable NATS leaf bundle for an edge site.

  Shared by the edge-site LiveView and `Api.EdgeSiteController` so both
  produce the same tarball: the leaf config pointing at the leaf server's
  stored upstream URL, the provisioned certificates and decrypted keys, the
  assignment-scoped direct leaf identities, and (only when a NATS account is
  configured) freshly minted leaf credentials.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.NatsLeafCredentials
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadarWebNg.Edge.EdgeSiteBundleGenerator

  require Ash.Query

  @doc """
  Returns `{:ok, tarball, filename}`.

  Errors:
    * `{:error, :leaf_not_ready}` - no leaf server, or it is not provisioned yet
    * `{:error, reason}` - credential minting, key decryption or tar failure
  """
  @spec build(map(), map() | nil, keyword()) :: {:ok, binary(), String.t()} | {:error, term()}
  def build(site, leaf_server, opts \\ [])

  def build(site, %{status: status} = leaf_server, opts) when status in [:provisioned, :connected, :disconnected] do
    with {:ok, leaf_key_pem, server_key_pem} <- decrypted_keys(leaf_server),
         {:ok, direct_leaf_identities} <- direct_leaf_identities(site.id),
         {:ok, nats_creds} <- NatsLeafCredentials.mint(site, Keyword.take(opts, [:account_client])),
         {:ok, tarball} <-
           EdgeSiteBundleGenerator.create_tarball(site, leaf_server, nats_creds,
             leaf_key_pem: leaf_key_pem,
             server_key_pem: server_key_pem,
             direct_leaf_identities: direct_leaf_identities
           ) do
      {:ok, tarball, EdgeSiteBundleGenerator.bundle_filename(site)}
    end
  end

  def build(_site, _leaf_server, _opts), do: {:error, :leaf_not_ready}

  @doc "True when the leaf server holds provisioned certificates."
  @spec leaf_ready?(map() | nil) :: boolean()
  def leaf_ready?(%{status: status}) when status in [:provisioned, :connected, :disconnected], do: true
  def leaf_ready?(_), do: false

  # The keys are AshCloak-encrypted: the stored columns are
  # `encrypted_*`, and the attribute names are decrypting calculations that
  # are not loaded by default.
  defp decrypted_keys(leaf_server) do
    case Ash.load(leaf_server, [:leaf_key_pem_ciphertext, :server_key_pem_ciphertext],
           actor: SystemActor.system(:edge_site_bundle_generator)
         ) do
      {:ok, %{leaf_key_pem_ciphertext: leaf_key, server_key_pem_ciphertext: server_key}}
      when is_binary(leaf_key) and leaf_key != "" and is_binary(server_key) and server_key != "" ->
        {:ok, leaf_key, server_key}

      {:ok, _} ->
        {:error, :leaf_not_ready}

      {:error, reason} ->
        {:error, {:leaf_key_decrypt_failed, reason}}
    end
  end

  defp direct_leaf_identities(site_id) do
    query =
      AddonAssignment
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(edge_site_id == ^site_id and enabled == true)

    case Ash.read(query, actor: SystemActor.system(:edge_site_bundle_generator)) do
      {:ok, assignments} ->
        {:ok,
         assignments
         |> Enum.filter(&direct_leaf_assignment?/1)
         |> Enum.map(&direct_leaf_identity/1)}

      {:error, reason} ->
        {:error, {:direct_leaf_identity_read_failed, reason}}
    end
  end

  defp direct_leaf_assignment?(assignment) do
    direct_backend?(assignment.params) and
      assignment.direct_access_status in [:pending, :ready] and
      is_binary(assignment.direct_identity_component_id) and
      is_binary(assignment.direct_identity_partition_id) and
      is_map(assignment.direct_subject_scope)
  end

  defp direct_backend?(params) when is_map(params) do
    output = Map.get(params, :output) || Map.get(params, "output") || %{}
    backend = Map.get(output, :backend) || Map.get(output, "backend")
    backend in [:jetstream, "jetstream"]
  end

  defp direct_backend?(_params), do: false

  defp direct_leaf_identity(assignment) do
    %{
      component_id: assignment.direct_identity_component_id,
      partition_id: assignment.direct_identity_partition_id,
      scope: assignment.direct_subject_scope
    }
  end
end
