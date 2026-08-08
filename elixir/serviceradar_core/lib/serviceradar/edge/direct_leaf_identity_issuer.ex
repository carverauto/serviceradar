defmodule ServiceRadar.Edge.DirectLeafIdentityIssuer do
  @moduledoc """
  Issues and revokes assignment-scoped mTLS identities through the gateway CA.

  Core never generates the private key or chooses a gateway from user input. It
  resolves the currently authenticated agent control session, derives the
  gateway node from that live session, and asks that gateway to issue an
  add-on certificate for the server-owned partition.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Edge.DirectLeafEligibility
  alias ServiceRadar.Edge.DirectLeafScope
  alias ServiceRadar.Edge.EdgeSite

  require Ash.Query
  require Logger

  @gateway_cert_issuer ServiceRadarAgentGateway.CertIssuer
  @gateway_revocation ServiceRadarAgentGateway.AgentCertificateRevocation
  @rpc_timeout 10_000

  @type identity_bundle :: %{
          required(:certificate_pem) => binary(),
          required(:private_key_pem) => binary(),
          required(:ca_chain_pem) => binary(),
          required(:certificate_fingerprint) => binary(),
          required(:component_id) => binary(),
          required(:partition_id) => binary(),
          required(:expires_at) => DateTime.t(),
          required(:scope) => map()
        }

  @spec issue(map(), keyword()) :: {:ok, identity_bundle()} | {:error, term()}
  def issue(assignment, opts \\ []) when is_map(assignment) do
    params = value(assignment, :params) || %{}
    edge_site_id = value(assignment, :edge_site_id)
    agent_uid = value(assignment, :agent_uid)
    assignment_id = value(assignment, :id)

    with true <- DirectLeafEligibility.direct?(params),
         {:ok, scope} <- DirectLeafScope.build(params),
         :ok <- ensure_scope_matches(assignment, scope),
         {:ok, edge_site} <- load_edge_site(edge_site_id, opts),
         leaf_server = value(edge_site, :nats_leaf_server),
         {:ok, _params} <- DirectLeafEligibility.validate(params, edge_site, leaf_server),
         {:ok, evidence} <- resolve_session(agent_uid, opts),
         :ok <- ensure_session_agent(evidence, agent_uid),
         {:ok, partition_id} <- authenticated_partition(evidence),
         {:ok, gateway_node} <- authenticated_gateway_node(evidence),
         {:ok, component_id} <- component_id(assignment_id),
         {:ok, bundle} <-
           issue_on_gateway(component_id, partition_id, gateway_node, assignment, opts) do
      {:ok,
       %{
         certificate_pem: Map.fetch!(bundle, :certificate_pem),
         private_key_pem: Map.fetch!(bundle, :private_key_pem),
         ca_chain_pem: Map.fetch!(bundle, :ca_chain_pem),
         certificate_fingerprint: Map.fetch!(bundle, :certificate_fingerprint),
         component_id: component_id,
         partition_id: partition_id,
         expires_at: DateTime.add(DateTime.utc_now(), validity_days(opts), :day),
         scope: scope,
         authorization_status: Keyword.get(opts, :authorization_status, :pending)
       }}
    else
      false -> {:error, :not_direct_leaf_assignment}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:direct_leaf_identity_issue_failed, Exception.message(error)}}
  end

  @doc "Best-effort revocation of a previously issued assignment identity."
  @spec revoke(map(), keyword()) :: :ok | {:error, term()}
  def revoke(identity, opts \\ []) when is_map(identity) do
    fingerprint =
      value(identity, :direct_certificate_fingerprint) ||
        value(identity, :certificate_fingerprint)

    component_id =
      value(identity, :direct_identity_component_id) || value(identity, :component_id)

    if blank?(fingerprint) and blank?(component_id) do
      :ok
    else
      with {:ok, evidence} <- resolve_session(value(identity, :agent_uid), opts),
           {:ok, gateway_node} <- authenticated_gateway_node(evidence) do
        reason = Keyword.get(opts, :reason, "direct leaf access revoked")
        revoke_identity_on_gateway(gateway_node, fingerprint, component_id, reason, opts)
      end
    end
  rescue
    error -> {:error, {:direct_leaf_identity_revoke_failed, Exception.message(error)}}
  end

  @doc false
  def revoke_identity_on_gateway(gateway_node, fingerprint, component_id, reason, opts \\ []) do
    rpc_call = Keyword.get(opts, :rpc_call, &:rpc.call/5)
    timeout = Keyword.get(opts, :rpc_timeout, @rpc_timeout)

    results =
      Enum.reject(
        [
          revoke_fingerprint(rpc_call, gateway_node, fingerprint, reason, timeout),
          revoke_component(rpc_call, gateway_node, component_id, reason, timeout)
        ],
        &(&1 == :skip)
      )

    cond do
      results == [] -> :ok
      Enum.all?(results, &(&1 == :ok)) -> :ok
      true -> {:error, {:gateway_revocation_failed, results}}
    end
  end

  defp issue_on_gateway(component_id, partition_id, gateway_node, assignment, opts) do
    rpc_call = Keyword.get(opts, :rpc_call, &:rpc.call/5)
    timeout = Keyword.get(opts, :rpc_timeout, @rpc_timeout)
    validity_days = validity_days(opts)
    actor = Keyword.get(opts, :actor, SystemActor.system(:direct_leaf_identity_issuer))

    issuer_opts = [
      validity_days: validity_days,
      authorized_component_id: component_id,
      authorized_partition_id: partition_id,
      audit_actor: actor,
      predecessor_certificate_fingerprint: value(assignment, :direct_certificate_fingerprint),
      predecessor_revocation_reason: "direct leaf identity rotated"
    ]

    case rpc_call.(
           gateway_node,
           @gateway_cert_issuer,
           :issue_agent_bundle,
           [component_id, partition_id, :addon, issuer_opts],
           timeout
         ) do
      {:ok, bundle} when is_map(bundle) -> {:ok, bundle}
      {:error, reason} -> {:error, {:gateway_identity_issue_failed, reason}}
      {:badrpc, reason} -> {:error, {:gateway_identity_issue_unreachable, reason}}
      other -> {:error, {:invalid_gateway_identity_response, other}}
    end
  end

  defp resolve_session(agent_uid, opts) do
    resolver =
      Keyword.get(opts, :session_resolver, &AgentCommandBus.resolve_control_session_evidence/1)

    resolver.(agent_uid)
  end

  defp load_edge_site(nil, _opts), do: {:error, :edge_site_not_selected}

  defp load_edge_site(edge_site_id, opts) do
    fetcher = Keyword.get(opts, :edge_site_fetcher, &fetch_edge_site/1)
    fetcher.(edge_site_id)
  end

  defp fetch_edge_site(edge_site_id) do
    actor = SystemActor.system(:direct_leaf_identity_issuer)

    EdgeSite
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^edge_site_id)
    |> Ash.Query.load([:nats_leaf_server])
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, :edge_site_not_found}
      {:ok, site} -> {:ok, site}
      {:error, reason} -> {:error, {:edge_site_lookup_failed, reason}}
    end
  end

  defp ensure_scope_matches(assignment, scope) do
    if value(assignment, :direct_subject_scope) == scope do
      :ok
    else
      {:error, :direct_subject_scope_stale}
    end
  end

  defp ensure_session_agent(evidence, agent_uid) do
    if value(evidence, :agent_id) == agent_uid do
      :ok
    else
      {:error, :authenticated_agent_mismatch}
    end
  end

  defp authenticated_partition(evidence) do
    case value(evidence, :partition_id) do
      partition when is_binary(partition) and partition != "" -> {:ok, partition}
      _ -> {:error, :authenticated_partition_unavailable}
    end
  end

  defp authenticated_gateway_node(evidence) do
    case value(evidence, :control_session_pid) do
      pid when is_pid(pid) -> {:ok, node(pid)}
      _ -> {:error, :authenticated_gateway_unavailable}
    end
  end

  defp component_id(nil), do: {:error, :assignment_id_missing}

  defp component_id(id) do
    component_id = "addon-" <> String.replace(to_string(id), "-", "")

    if Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, component_id) do
      {:ok, component_id}
    else
      {:error, :invalid_assignment_id}
    end
  end

  defp revoke_fingerprint(_rpc_call, _node, fingerprint, _reason, _timeout)
       when not is_binary(fingerprint), do: :skip

  defp revoke_fingerprint(rpc_call, gateway_node, fingerprint, reason, timeout) do
    case rpc_call.(
           gateway_node,
           @gateway_revocation,
           :revoke_fingerprint,
           [fingerprint, [reason: reason]],
           timeout
         ) do
      :ok -> :ok
      {:badrpc, reason} -> {:error, {:fingerprint, reason}}
      other -> {:error, {:fingerprint, other}}
    end
  end

  defp revoke_component(_rpc_call, _node, component_id, _reason, _timeout)
       when not is_binary(component_id), do: :skip

  defp revoke_component(rpc_call, gateway_node, component_id, reason, timeout) do
    case rpc_call.(
           gateway_node,
           @gateway_revocation,
           :revoke_component_id,
           [component_id, [reason: reason]],
           timeout
         ) do
      :ok -> :ok
      {:badrpc, reason} -> {:error, {:component_id, reason}}
      other -> {:error, {:component_id, other}}
    end
  end

  defp validity_days(opts) do
    days = Keyword.get(opts, :validity_days, 30)
    if is_integer(days) and days > 0, do: days, else: 30
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_map, _key), do: nil

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
