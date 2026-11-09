defmodule ServiceRadar.Edge.LocalBinding do
  @moduledoc """
  The frozen, field-framed local attribution digest. This checks stored evidence's
  shape; only `RecoveryAttribution` can establish its relation to a record before
  append. Source presence and active/passive classification are independent.
  """

  alias ServiceRadar.Edge.PlanValidate
  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadar.Edge.RecoveryValidate
  alias ServiceRadar.Edge.SemanticValidate
  alias Serviceradar.Edge.V1.EdgeAttributedActiveV1
  alias Serviceradar.Edge.V1.EdgeAttributedPassiveV1
  alias Serviceradar.Edge.V1.EdgeClassificationSpanV1
  alias Serviceradar.Edge.V1.EdgeRecordLaneOpen
  alias Serviceradar.Edge.V1.EdgeRecordRouteProfile
  alias Serviceradar.Edge.V1.EdgeRecordTrafficClass
  alias Serviceradar.Edge.V1.EdgeSourceAuthorizationKind

  @version 1
  @domain "serviceradar.edge.recovery.local_binding.v1"
  @u64_max 0xFFFFFFFFFFFFFFFF

  @doc "The independently versioned on-disk grammar."
  def version, do: @version

  @spec digest(term(), term(), term()) :: {:ok, binary()} | {:error, atom()}
  def digest(version, _coordinates, _attribution) when version != @version,
    do: {:error, :local_binding_version}

  def digest(@version, coordinates, attribution) do
    with :ok <- validate(coordinates, attribution) do
      {:ok, :crypto.hash(:sha256, transcript(coordinates, attribution))}
    end
  end

  defp validate(c, %{active: active, identity: identity, range_sha256: range})
       when is_map(c) and is_boolean(active) and is_binary(range) do
    lane = %EdgeRecordLaneOpen{
      route_profile: Map.get(c, :lane_route_profile),
      traffic_class: Map.get(c, :lane_traffic_class)
    }

    classification =
      if active do
        {:attributed_active, %EdgeAttributedActiveV1{identity: identity, range_sha256: range}}
      else
        {:attributed_passive, %EdgeAttributedPassiveV1{identity: identity}}
      end

    span = %EdgeClassificationSpanV1{
      from_sequence: 1,
      through_sequence: 1,
      classification: classification
    }

    with true <- PlanValidate.canonical_uuid?(Map.get(c, :network_scope_id)),
         true <-
           PublicationIdentity.valid_authenticated_principal?(Map.get(c, :authenticated_agent_id)),
         true <- PlanValidate.uuidv7?(Map.get(c, :spool_generation_id)),
         true <- PlanValidate.uuidv7?(Map.get(c, :event_id)),
         true <- u64?(Map.get(c, :sequence)) and c.sequence > 0,
         true <- digest32?(Map.get(c, :record_sha256)),
         true <- active or range == "",
         :ok <- SemanticValidate.validate_lane_open(lane),
         :ok <- RecoveryValidate.attributed_span(span) do
      :ok
    else
      _ -> {:error, :local_binding}
    end
  end

  defp validate(_coordinates, _attribution), do: {:error, :local_binding}

  defp transcript(c, a) do
    id = a.identity

    [
      bytes(@domain),
      u64(@version),
      bytes(c.network_scope_id),
      bytes(c.authenticated_agent_id),
      u64(enum_value(EdgeRecordRouteProfile, c.lane_route_profile)),
      u64(enum_value(EdgeRecordTrafficClass, c.lane_traffic_class)),
      bytes(c.spool_generation_id),
      u64(c.sequence),
      bytes(c.event_id),
      bytes(c.record_sha256),
      present(a.active),
      bytes(id.contract_bundle_sha256),
      bytes(id.producer_assignment_id),
      bytes(id.run_id),
      u64(id.run_shard),
      u64(id.authority_epoch),
      bytes(id.production_scope_id),
      bytes(id.scope_sha256),
      source(id.source),
      if(a.active, do: bytes(a.range_sha256), else: [])
    ]
  end

  defp source(nil), do: present(false)

  defp source(s) do
    [
      present(true),
      u64(enum_value(EdgeSourceAuthorizationKind, s.kind)),
      bytes(s.context_id),
      bytes(s.source_scope_id),
      bytes(s.source_scope_sha256)
    ]
  end

  defp enum_value(_module, value) when is_integer(value), do: value
  defp enum_value(module, value), do: module.value(value)
  defp u64?(value), do: is_integer(value) and value >= 0 and value <= @u64_max
  defp digest32?(value), do: is_binary(value) and byte_size(value) == 32
  defp u64(value), do: <<value::unsigned-big-64>>
  defp bytes(value), do: [u64(byte_size(value)), value]
  defp present(true), do: <<1>>
  defp present(false), do: <<0>>
end
