defmodule ServiceRadarAgentGateway.MetricEnvelopeAttestation do
  @moduledoc false

  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricResource

  @metric_schema "serviceradar.metric.v1"

  @spec attest(MetricBatch.t(), map(), map(), keyword()) :: MetricBatch.t()
  def attest(%MetricBatch{} = batch, status, ingress_context, opts) when is_map(status) do
    resource = attest_resource(batch.resource || %MetricResource{}, status)
    identity = attest_identity(batch.ingest_identity || %IngestIdentity{}, status, opts)

    %{
      batch
      | resource: resource,
        ingest_identity: identity,
        ingress_id: string_value(ingress_context[:ingress_id]) || batch.ingress_id,
        ingress_timestamp_unix_nano:
          positive_int(ingress_context[:ingress_time_unix_nano]) ||
            batch.ingress_timestamp_unix_nano
    }
  end

  defp attest_resource(%MetricResource{} = resource, status) do
    %{
      resource
      | agent_id: string_value(status[:agent_id]) || resource.agent_id,
        gateway_id: string_value(status[:gateway_id]) || resource.gateway_id,
        partition: string_value(status[:partition]) || resource.partition,
        service_name: string_value(status[:service_name]) || resource.service_name,
        service_type: string_value(status[:service_type]) || resource.service_type
    }
  end

  defp attest_identity(%IngestIdentity{} = identity, status, opts) do
    gateway_id = string_value(status[:gateway_id])

    %{
      identity
      | source: option_string(opts, :source) || string_value(status[:source]) || identity.source,
        payload_kind: @metric_schema,
        producer_id: option_string(opts, :producer_id) || identity.producer_id,
        producer_kind: option_string(opts, :producer_kind) || identity.producer_kind,
        attested_by: gateway_id || identity.attested_by
    }
  end

  defp option_string(opts, key), do: opts |> Keyword.get(key) |> string_value()

  defp string_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp string_value(value) when is_atom(value), do: value |> Atom.to_string() |> string_value()
  defp string_value(value) when is_integer(value), do: Integer.to_string(value)
  defp string_value(_value), do: nil

  defp positive_int(value) when is_integer(value) and value > 0, do: value
  defp positive_int(_value), do: nil
end
