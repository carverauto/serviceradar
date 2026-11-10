defmodule ServiceRadar.Edge.RecoveryAssignmentEvidence do
  @moduledoc """
  Constructs mapping evidence at the core issuance boundary from the exact signed
  authority being delivered. This is not a public backfill/import interface.
  The original issuer public key is retained so key rotation cannot erase proof.
  """

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.RecoveryAssignment
  alias Serviceradar.Edge.V1.EdgeAttributedActiveV1
  alias Serviceradar.Edge.V1.EdgeAttributedPassiveV1
  alias Serviceradar.Edge.V1.EdgeAttributedSpanIdentityV1
  alias Serviceradar.Edge.V1.EdgeClassificationSpanV1
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias Serviceradar.Edge.V1.EdgeSourceAuthorizationV1
  alias Serviceradar.Edge.V1.EdgeSourceSpanIdentityV1

  @doc "Original explicit-negative evidence for an issued passive standing grant."
  def standing(capability, public_key),
    do: construct(capability, nil, public_key, "standing_output_grant", nil)

  @doc "Original positive evidence for every source-authorized range in a delivered sweep slot."
  def sweep(capability, slot, public_key) do
    slot.source_authorizations
    |> Enum.reduce_while({:ok, []}, fn source, {:ok, entries} ->
      metadata = %{
        "execution_id" => hex(slot.execution_id),
        "plan_id" => hex(slot.plan_header.execution_plan_id),
        "plan_sha256" => hex(slot.plan_header.execution_plan_sha256)
      }

      case construct(capability, source, public_key, "scheduled_sweep", metadata) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  @doc "Original explicit-negative evidence for source-authorized passive recovery control."
  def recovery_control(capability, source, public_key),
    do: construct(capability, source, public_key, "recovery_control", nil)

  @doc "Verifies retained original evidence against its exact mapping key and tagged value."
  def validate(key, value, proof) do
    with %{
           "issuer" => issuer,
           "public_key" => pk,
           "production" => production,
           "source" => source,
           "metadata" => metadata
         }
         when is_binary(pk) and is_binary(production) <- proof,
         true <- map_size(proof) == 5,
         {:ok, public_key} <- Base.decode64(pk),
         {:ok, capability_bytes} <- Base.decode64(production),
         {:ok, capability} <- decode(EdgeSignedCapabilityV1, capability_bytes),
         {:ok, source} <- decode_source(source),
         {:ok, entry} <- construct(capability, source, public_key, issuer, metadata),
         true <- entry.key == key and entry.value == value do
      :ok
    else
      _ -> {:error, :invalid_issuance}
    end
  end

  defp construct(
         %EdgeSignedCapabilityV1{claims: {:production, production}} = capability,
         source,
         <<_::256>> = public_key,
         issuer,
         metadata
       ) do
    with true <- CapabilitySigning.verify(capability, :production, public_key),
         :ok <- verify_source(source, production, public_key),
         {:ok, span, value} <- attribution(production, source, issuer, metadata),
         {:ok, key} <-
           RecoveryAssignment.key(
             production.network_scope_id,
             production.origin_principal_id,
             span
           ),
         :ok <- RecoveryAssignment.validate_value(key, value) do
      {:ok,
       %{
         key: key,
         value: value,
         proof: %{
           "issuer" => issuer,
           "public_key" => Base.encode64(public_key),
           "production" => capability |> EdgeSignedCapabilityV1.encode() |> Base.encode64(),
           "source" => encode_source(source),
           "metadata" => metadata
         }
       }}
    else
      _ -> {:error, :invalid_issuance}
    end
  end

  defp construct(_, _, _, _, _), do: {:error, :invalid_issuance}

  defp attribution(
         production,
         source,
         "scheduled_sweep",
         %{"execution_id" => execution, "plan_id" => plan, "plan_sha256" => plan_sha256} =
           metadata
       )
       when map_size(metadata) == 3 do
    with %EdgeSourceAuthorizationV1{
           kind: :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP,
           capability: %{claims: {:source, claims}}
         } <- source,
         true <-
           execution == hex(claims.context_id) and
             claims.target_range_sha256 == source.scope_sha256 and
             plan_sha256 == hex(claims.execution_plan_sha256) do
      span = %EdgeClassificationSpanV1{
        from_sequence: 1,
        through_sequence: 1,
        classification:
          {:attributed_active,
           %EdgeAttributedActiveV1{
             identity: identity(production, source),
             range_sha256: source.scope_sha256
           }}
      }

      {:ok, span,
       %{
         "version" => 1,
         "kind" => "positive",
         "execution_id" => execution,
         "plan" => %{"id" => plan, "sha256" => hex(claims.execution_plan_sha256)},
         "range" => %{"id" => hex(source.scope_id), "sha256" => hex(source.scope_sha256)},
         "execution_shard" => production.run_shard,
         "assignment_epoch" => production.authority_epoch,
         "correlation" => %{"kind" => "execution_id", "id" => execution}
       }}
    else
      _ -> {:error, :invalid_issuance}
    end
  end

  defp attribution(production, source, reason, nil)
       when reason in ["standing_output_grant", "recovery_control"] do
    span = %EdgeClassificationSpanV1{
      from_sequence: 1,
      through_sequence: 1,
      classification:
        {:attributed_passive, %EdgeAttributedPassiveV1{identity: identity(production, source)}}
    }

    {:ok, span,
     %{
       "version" => 1,
       "kind" => "explicit_negative",
       "reason" => reason,
       "authority" => %{
         "producer_assignment_id" => hex(production.producer_assignment_id),
         "authority_epoch" => production.authority_epoch
       }
     }}
  end

  defp attribution(_, _, _, _), do: {:error, :invalid_issuance}

  defp identity(production, source) do
    %EdgeAttributedSpanIdentityV1{
      producer_assignment_id: production.producer_assignment_id,
      run_id: production.run_id,
      run_shard: production.run_shard,
      authority_epoch: production.authority_epoch,
      production_scope_id: production.scope_id,
      scope_sha256: production.scope_sha256,
      contract_bundle_sha256: production.contract_bundle_sha256,
      source: source_identity(source)
    }
  end

  defp source_identity(nil), do: nil

  defp source_identity(source),
    do: %EdgeSourceSpanIdentityV1{
      kind: source.kind,
      context_id: source.context_id,
      source_scope_id: source.scope_id,
      source_scope_sha256: source.scope_sha256
    }

  defp verify_source(nil, _, _), do: :ok

  defp verify_source(
         %EdgeSourceAuthorizationV1{capability: %{claims: {:source, claims}}} = source,
         production,
         public_key
       ) do
    joined_fields = [
      :network_scope_id,
      :origin_principal_id,
      :producer_instance_id,
      :producer_assignment_id,
      :run_id,
      :run_shard,
      :authority_epoch,
      :traffic_class,
      :route_profile,
      :origin_kind
    ]

    if source.__unknown_fields__ == [] and
         CapabilitySigning.verify(source.capability, :source, public_key) and
         Enum.all?(joined_fields, &(Map.fetch!(claims, &1) == Map.fetch!(production, &1))) and
         source.kind == claims.kind and source.context_id == claims.context_id and
         source.scope_id == claims.scope_id and source.scope_sha256 == claims.scope_sha256,
       do: :ok,
       else: {:error, :invalid_issuance}
  end

  defp verify_source(_, _, _), do: {:error, :invalid_issuance}
  defp encode_source(nil), do: nil
  defp encode_source(source), do: source |> EdgeSourceAuthorizationV1.encode() |> Base.encode64()
  defp decode_source(nil), do: {:ok, nil}

  defp decode_source(encoded) when is_binary(encoded) do
    with {:ok, bytes} <- Base.decode64(encoded), do: decode(EdgeSourceAuthorizationV1, bytes)
  end

  defp decode_source(_), do: {:error, :invalid_issuance}

  defp decode(module, bytes) do
    {:ok, module.decode(bytes)}
  rescue
    _ -> {:error, :invalid_issuance}
  end

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
end
