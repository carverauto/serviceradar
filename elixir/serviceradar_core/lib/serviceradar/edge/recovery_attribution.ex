defmodule ServiceRadar.Edge.RecoveryAttribution do
  @moduledoc """
  Attribution derived from a record's own validated body and signed authority.
  Constructors compose the existing typed validators. `bind/3` compares the whole
  proposed attribution and exact physical record identity before a sidecar can be
  written. No generic constructor accepts a caller-selected range or validator.
  """

  alias ServiceRadar.Edge.ContractCatalog
  alias ServiceRadar.Edge.LocalBinding
  alias ServiceRadar.Edge.MetricsBatchProjection
  alias ServiceRadar.Edge.Projectors.SweepObservation
  alias ServiceRadar.Edge.RecordValidate
  alias ServiceRadar.Edge.RecoveryValidate
  alias Serviceradar.Edge.V1.EdgeAttributedActiveV1
  alias Serviceradar.Edge.V1.EdgeAttributedPassiveV1
  alias Serviceradar.Edge.V1.EdgeAttributedSpanIdentityV1
  alias Serviceradar.Edge.V1.EdgeClassificationSpanV1
  alias Serviceradar.Edge.V1.EdgeRecoveryControlPayloadV1
  alias Serviceradar.Edge.V1.EdgeSourceSpanIdentityV1

  @enforce_keys [:attribution, :record_identity]
  defstruct [:attribution, :record_identity]

  @opaque t :: %__MODULE__{attribution: map(), record_identity: map()}

  @doc "Derive production attribution using the catalog's authority and typed projector."
  @spec registered(binary(), struct(), map()) :: {:ok, t()} | {:error, term()}
  def registered(raw, expected_contract, policy) do
    with {:ok, record} <- signed_record(raw, expected_contract, policy),
         {:ok, entry} <-
           ContractCatalog.fetch(
             {record.output_contract.contract_id, record.output_contract.contract_version}
           ),
         {:ok, body} <- entry.projector.decode(record) do
      derive_registered(raw, record, entry.authority, body)
    else
      :error -> {:error, :contract_dispatch}
      error -> error
    end
  end

  defp derive_registered(raw, record, :sweep_lease, %{target_range_sha256: range}),
    do: derive(raw, record, true, range)

  defp derive_registered(
         raw,
         %{
           output_contract: %{
             contract_id: "serviceradar.edge.recovery_control",
             contract_version: 1
           },
           source_authorization: %{kind: :EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL}
         } = record,
         :standing_grant,
         %{payload: %EdgeRecoveryControlPayloadV1{}}
       ),
       do: derive(raw, record, false, "")

  defp derive_registered(raw, %{source_authorization: nil} = record, :standing_grant, _body),
    do: derive(raw, record, false, "")

  defp derive_registered(_raw, _record, _authority, _body), do: {:error, :attribution_join}

  @spec sweep(binary(), struct(), map()) :: {:ok, t()} | {:error, term()}
  def sweep(raw, expected_contract, policy) do
    with {:ok, record} <- signed_record(raw, expected_contract, policy),
         {:ok, body} <- SweepObservation.decode(record) do
      derive(raw, record, true, body.target_range_sha256)
    end
  end

  @spec control(binary(), struct(), map()) :: {:ok, t()} | {:error, term()}
  def control(raw, expected_contract, policy) do
    with {:ok, record} <- RecordValidate.validate_bytes(raw),
         :ok <- RecoveryValidate.recovery_control(record, expected_contract, policy) do
      derive(raw, record, false, "")
    end
  end

  @spec metrics(binary(), map()) :: {:ok, t()} | {:error, term()}
  def metrics(raw, policy) do
    with {:ok, record} <- RecordValidate.validate_bytes(raw),
         true <-
           record.output_contract.contract_id == "serviceradar.metrics.batch" and
             record.output_contract.contract_version == 1,
         :ok <- RecoveryValidate.record_signed(record, policy),
         {:ok, _body} <- MetricsBatchProjection.decode(record) do
      derive(raw, record, false, "")
    else
      false -> {:error, :contract_dispatch}
      error -> error
    end
  end

  @doc "The complete derived classification, suitable for independent durable storage."
  def attribution(%__MODULE__{attribution: attribution}), do: attribution

  @doc "A normalized singleton classification for identity-only historical mapping lookup."
  @spec classification(t()) :: EdgeClassificationSpanV1.t()
  def classification(%__MODULE__{attribution: a}) do
    body =
      if a.active do
        {:attributed_active,
         %EdgeAttributedActiveV1{identity: a.identity, range_sha256: a.range_sha256}}
      else
        {:attributed_passive, %EdgeAttributedPassiveV1{identity: a.identity}}
      end

    %EdgeClassificationSpanV1{from_sequence: 1, through_sequence: 1, classification: body}
  end

  @doc "Join before hashing; relocation may change only generation and sequence."
  @spec bind(t(), map(), map()) :: {:ok, binary()} | {:error, atom()}
  def bind(
        %__MODULE__{attribution: expected, record_identity: identity},
        coordinates,
        attribution
      )
      when is_map(coordinates) do
    if expected == attribution and Map.take(coordinates, Map.keys(identity)) == identity do
      LocalBinding.digest(LocalBinding.version(), coordinates, attribution)
    else
      {:error, :attribution_join}
    end
  end

  def bind(_validated, _coordinates, _attribution), do: {:error, :attribution_join}

  defp signed_record(raw, expected_contract, policy) do
    with {:ok, record} <- RecordValidate.validate_bytes(raw),
         :ok <- RecoveryValidate.contract_dispatch(record, expected_contract),
         :ok <- RecoveryValidate.record_signed(record, policy) do
      {:ok, record}
    end
  end

  defp derive(
         raw,
         %{producer_context: %{origin_kind: :EDGE_ORIGIN_KIND_AGENT} = p} = r,
         active,
         range
       ) do
    attribution = %{
      active: active,
      range_sha256: range,
      identity: %EdgeAttributedSpanIdentityV1{
        contract_bundle_sha256: r.output_contract.contract_bundle_sha256,
        producer_assignment_id: p.producer_assignment_id,
        run_id: p.run_id,
        run_shard: p.run_shard,
        authority_epoch: p.authority_epoch,
        production_scope_id: p.scope_id,
        scope_sha256: p.scope_sha256,
        source: source_identity(r.source_authorization)
      }
    }

    {:ok,
     %__MODULE__{
       attribution: attribution,
       record_identity: %{
         network_scope_id: r.network_scope_id,
         authenticated_agent_id: p.origin_principal_id,
         lane_route_profile: r.route_profile,
         lane_traffic_class: r.traffic_class,
         event_id: r.event_id,
         record_sha256: :crypto.hash(:sha256, raw)
       }
     }}
  end

  defp derive(_raw, _record, _active, _range), do: {:error, :attribution_join}
  defp source_identity(nil), do: nil

  defp source_identity(s) do
    %EdgeSourceSpanIdentityV1{
      kind: s.kind,
      context_id: s.context_id,
      source_scope_id: s.scope_id,
      source_scope_sha256: s.scope_sha256
    }
  end
end
