defmodule ServiceRadar.Bench.MetricFixtureProfile do
  @moduledoc false

  alias Serviceradar.Metric.V1.MetricBatch

  @default_fixture_dir "tmp/metric-fixtures/demo-smoke-cli"
  @default_observed_messages_per_second 0.683
  @default_current_agents 13
  @default_target_agents 50_000
  @default_durable_consumers 3

  def run do
    fixture_dir = env("METRIC_FIXTURE_PROFILE_DIR", @default_fixture_dir)

    observed_messages_per_second =
      env_float("OBSERVED_METRIC_MESSAGES_PER_SECOND", @default_observed_messages_per_second)

    current_agents = env_int("CURRENT_AGENT_COUNT", @default_current_agents)
    target_agents = env_int("TARGET_AGENT_COUNT", @default_target_agents)
    durable_consumers = env_int("DURABLE_CONSUMER_COUNT", @default_durable_consumers)

    profiles =
      fixture_dir
      |> fixture_paths()
      |> Enum.map(&profile_fixture/1)

    totals = totals(profiles)
    averages = averages(totals)
    observed = observed(totals, averages, observed_messages_per_second, durable_consumers)
    target = target(observed, current_agents, target_agents)

    print_report(%{
      fixture_dir: fixture_dir,
      files: profiles,
      totals: totals,
      averages: averages,
      observed: observed,
      target: target,
      current_agents: current_agents,
      target_agents: target_agents,
      durable_consumers: durable_consumers
    })
  end

  defp fixture_paths(dir) do
    dir
    |> Path.expand()
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end

  defp profile_fixture(path) do
    payload =
      path
      |> File.read!()
      |> strip_raw_cli_newline()

    batch = MetricBatch.decode(payload)
    metrics = batch.metrics || []
    points = Enum.reduce(metrics, 0, fn metric, acc -> acc + length(metric.points || []) end)

    %{
      path: path,
      bytes: byte_size(payload),
      metrics: length(metrics),
      points: points,
      resource: compact_resource(batch.resource),
      ingest_identity: compact_ingest_identity(batch.ingest_identity),
      top_metric_names: top_metric_names(metrics)
    }
  end

  defp compact_resource(nil), do: %{}

  defp compact_resource(resource) do
    reject_nil_values(%{
      agent_id: blank_to_nil(resource.agent_id),
      gateway_id: blank_to_nil(resource.gateway_id),
      host_ip: blank_to_nil(resource.host_ip),
      target_device_ip: blank_to_nil(resource.target_device_ip),
      device_id: blank_to_nil(resource.device_id),
      service_name: blank_to_nil(resource.service_name),
      service_type: blank_to_nil(resource.service_type)
    })
  end

  defp compact_ingest_identity(nil), do: %{}

  defp compact_ingest_identity(identity) do
    reject_nil_values(%{
      source: blank_to_nil(identity.source),
      payload_kind: blank_to_nil(identity.payload_kind),
      producer_id: blank_to_nil(identity.producer_id),
      producer_kind: blank_to_nil(identity.producer_kind),
      attested_by: blank_to_nil(identity.attested_by)
    })
  end

  defp top_metric_names(metrics) do
    metrics
    |> Enum.map(&blank_to_nil(&1.name))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_name, count} -> -count end)
    |> Enum.take(8)
  end

  defp totals(profiles) do
    Enum.reduce(
      profiles,
      %{files: 0, bytes: 0, metrics: 0, points: 0},
      fn profile, acc ->
        %{
          files: acc.files + 1,
          bytes: acc.bytes + profile.bytes,
          metrics: acc.metrics + profile.metrics,
          points: acc.points + profile.points
        }
      end
    )
  end

  defp averages(%{files: files, bytes: bytes, metrics: metrics, points: points}) do
    %{
      bytes_per_message: safe_div(bytes, files),
      metrics_per_message: safe_div(metrics, files),
      points_per_message: safe_div(points, files),
      bytes_per_point: safe_div(bytes, points),
      points_per_metric: safe_div(points, metrics)
    }
  end

  defp observed(totals, averages, messages_per_second, durable_consumers) do
    points_per_second = messages_per_second * averages.points_per_message
    bytes_per_second = messages_per_second * averages.bytes_per_message

    %{
      messages_per_second: messages_per_second,
      points_per_second: points_per_second,
      db_rows_per_second: points_per_second,
      stream_bytes_per_second: bytes_per_second,
      consumer_fanout_bytes_per_second: bytes_per_second * durable_consumers,
      points_in_fixture: totals.points,
      bytes_in_fixture: totals.bytes
    }
  end

  defp target(observed, current_agents, target_agents) do
    scale = safe_div(target_agents, current_agents)

    %{
      scale_factor: scale,
      messages_per_second: observed.messages_per_second * scale,
      points_per_second: observed.points_per_second * scale,
      db_rows_per_second: observed.db_rows_per_second * scale,
      stream_bytes_per_second: observed.stream_bytes_per_second * scale,
      consumer_fanout_bytes_per_second: observed.consumer_fanout_bytes_per_second * scale
    }
  end

  defp print_report(report) do
    IO.puts("Metric fixture profile")
    IO.puts("fixture_dir=#{report.fixture_dir}")
    IO.puts("files=#{report.totals.files}")
    IO.puts("")

    IO.puts("Captured fixture shape")
    IO.puts("payload_bytes=#{report.totals.bytes}")
    IO.puts("metric_points=#{report.totals.points}")
    IO.puts("metrics=#{report.totals.metrics}")
    IO.puts("avg_bytes_per_message=#{fmt(report.averages.bytes_per_message)}")
    IO.puts("avg_points_per_message=#{fmt(report.averages.points_per_message)}")
    IO.puts("avg_bytes_per_point=#{fmt(report.averages.bytes_per_point)}")
    IO.puts("avg_points_per_metric=#{fmt(report.averages.points_per_metric)}")
    IO.puts("")

    IO.puts("Observed demo rate model")
    IO.puts("assumed_current_agents=#{report.current_agents}")
    IO.puts("observed_messages_per_second=#{fmt(report.observed.messages_per_second)}")
    IO.puts("observed_points_per_second=#{fmt(report.observed.points_per_second)}")
    IO.puts("observed_db_rows_per_second=#{fmt(report.observed.db_rows_per_second)}")
    IO.puts("observed_stream_mib_per_second=#{fmt(mib(report.observed.stream_bytes_per_second))}")
    IO.puts("durable_consumers=#{report.durable_consumers}")

    IO.puts(
      "observed_consumer_fanout_mib_per_second=#{fmt(mib(report.observed.consumer_fanout_bytes_per_second))}"
    )

    IO.puts("")

    IO.puts("#{report.target_agents}-agent linear projection")
    IO.puts("scale_factor=#{fmt(report.target.scale_factor)}")
    IO.puts("target_messages_per_second=#{fmt(report.target.messages_per_second)}")
    IO.puts("target_points_per_second=#{fmt(report.target.points_per_second)}")
    IO.puts("target_db_rows_per_second=#{fmt(report.target.db_rows_per_second)}")
    IO.puts("target_stream_mib_per_second=#{fmt(mib(report.target.stream_bytes_per_second))}")

    IO.puts(
      "target_consumer_fanout_mib_per_second=#{fmt(mib(report.target.consumer_fanout_bytes_per_second))}"
    )

    IO.puts("")
    IO.puts("Fixture identities")

    Enum.each(report.files, fn profile ->
      IO.puts(
        "#{Path.basename(profile.path)} bytes=#{profile.bytes} points=#{profile.points} metrics=#{profile.metrics} " <>
          "resource=#{inspect(profile.resource)} ingest=#{inspect(profile.ingest_identity)}"
      )
    end)
  end

  defp strip_raw_cli_newline(payload) do
    case payload do
      <<body::binary-size(byte_size(payload) - 1), ?\n>> -> body
      _ -> payload
    end
  end

  defp env(name, default), do: System.get_env(name) || default

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> parse_int(value, default)
    end
  end

  defp env_float(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> parse_float(value, default)
    end
  end

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp parse_float(value, default) do
    case Float.parse(value) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp safe_div(_numerator, denominator) when denominator in [0, 0.0], do: 0.0
  defp safe_div(numerator, denominator), do: numerator / denominator

  defp mib(bytes), do: bytes / 1_048_576

  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value), do: to_string(value)

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end

ServiceRadar.Bench.MetricFixtureProfile.run()
