defmodule ServiceRadar.Observability.TelemetryJsonApiTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability

  @identities [
    {Observability.CpuMetric, [:timestamp, :gateway_id, :core_id]},
    {Observability.MemoryMetric, [:timestamp, :gateway_id]},
    {Observability.DiskMetric, [:timestamp, :gateway_id, :mount_point]},
    {Observability.ProcessMetric, [:timestamp, :gateway_id, :pid]},
    {Observability.TimeseriesMetric, [:timestamp, :gateway_id, :series_key]},
    {Observability.CpuMetricHourly, [:bucket, :device_id, :host_id]},
    {Observability.MemoryMetricHourly, [:bucket, :device_id, :host_id]},
    {Observability.DiskMetricHourly, [:bucket, :device_id, :host_id, :mount_point]},
    {Observability.ProcessMetricHourly, [:bucket, :device_id, :host_id, :name]},
    {Observability.TimeseriesMetricHourly, [:bucket, :device_id, :metric_type, :metric_name]},
    {Observability.TimeseriesMetricInterfaceHourly,
     [:bucket, :device_id, :target_device_ip, :if_index, :metric_type, :metric_name, :series_key]},
    {Observability.CpuClusterMetric, [:timestamp, :gateway_id, :cluster]},
    {Observability.OtelMetric, [:timestamp, :span_name, :service_name, :span_id]},
    {Observability.OtelMetricPoint, [:timestamp, :metric_name, :service_name, :attributes_hash]},
    {Observability.OtelTrace, [:timestamp, :trace_id, :span_id]},
    {Observability.OtelTraceSummary, [:trace_id]},
    {Observability.ServiceStatus, [:timestamp, :gateway_id, :service_name]},
    {Observability.CapacityForecast,
     [:forecasted_at, :resource_key, :metric_name, :horizon_seconds]}
  ]

  test "telemetry JSON:API IDs distinguish each row identity dimension" do
    for {resource, keys} <- @identities do
      attributes =
        Map.new(keys, fn key ->
          value =
            case key do
              time when time in [:timestamp, :bucket, :forecasted_at] ->
                ~U[2026-01-01 00:00:00.000000Z]

              number when number in [:core_id, :pid, :if_index, :horizon_seconds] ->
                1

              :target_device_ip ->
                "192.0.2.1"

              _ ->
                "synthetic"
            end

          {key, value}
        end)

      record = struct!(resource, attributes)
      id = AshJsonApi.encode_primary_key(record)
      assert is_binary(id) and byte_size(id) > 0, inspect(resource)
      assert AshJsonApi.encode_primary_key(record) == id

      for key <- keys do
        value =
          case Map.fetch!(attributes, key) do
            %DateTime{} = time -> DateTime.add(time, 1, :microsecond)
            number when is_integer(number) -> number + 1
            "192.0.2.1" -> "192.0.2.2"
            string -> string <> "-other"
          end

        refute AshJsonApi.encode_primary_key(Map.replace!(record, key, value)) == id,
               "#{inspect(resource)} must distinguish #{key}"
      end
    end
  end

  test "compiled telemetry index actions require bounded offset pages" do
    resources = [Observability.Log | Enum.map(@identities, &elem(&1, 0))]

    for resource <- resources do
      [route] = AshJsonApi.Resource.Info.routes(resource)
      assert route.action == :api_index, inspect(resource)
      action = Ash.Resource.Info.action(resource, route.action, :read)
      assert action.pagination.offset?, inspect(resource)
      assert action.pagination.required?, inspect(resource)
      assert action.pagination.default_limit == 100, inspect(resource)
      assert action.pagination.max_page_size == 1000, inspect(resource)
    end
  end

  test "internal telemetry reads remain unpaginated primary actions" do
    resources = [Observability.Log | Enum.map(@identities, &elem(&1, 0))]

    for resource <- resources do
      action = Ash.Resource.Info.primary_action(resource, :read)
      assert action.name == :read, inspect(resource)
      refute action.pagination, inspect(resource)
    end
  end
end
