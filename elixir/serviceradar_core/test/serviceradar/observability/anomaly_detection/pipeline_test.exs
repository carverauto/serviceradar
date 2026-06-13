defmodule ServiceRadar.Observability.AnomalyDetection.PipelineTest do
  use ExUnit.Case, async: false

  alias Broadway.Message
  alias ServiceRadar.Observability.AnomalyDetection.Config
  alias ServiceRadar.Observability.AnomalyDetection.Pipeline

  setup do
    previous_context_engine =
      Application.get_env(:serviceradar_core, :anomaly_detection_context_engine)

    previous_verdict_emitter =
      Application.get_env(:serviceradar_core, :anomaly_detection_verdict_emitter)

    previous_pid = Application.get_env(:serviceradar_core, :anomaly_detection_pipeline_test_pid)

    Application.put_env(
      :serviceradar_core,
      :anomaly_detection_context_engine,
      __MODULE__.ContextEngineStub
    )

    Application.put_env(:serviceradar_core, :anomaly_detection_pipeline_test_pid, self())
    Pipeline.reset_active_series_for_test()

    on_exit(fn ->
      Pipeline.reset_active_series_for_test()
      restore_env(:anomaly_detection_context_engine, previous_context_engine)
      restore_env(:anomaly_detection_verdict_emitter, previous_verdict_emitter)
      restore_env(:anomaly_detection_pipeline_test_pid, previous_pid)
    end)

    :ok
  end

  test "acks disabled subjects without invoking the reasoner" do
    message = message("metrics.sysmon.memory", sysmon_envelope("memory"))
    config = config(enabled_subjects: ["otel.metrics.>"])

    assert ^message = Pipeline.handle_message(:default, message, config)
    refute_receive {:evaluate, _sample}
  end

  test "Broadway topology scales processors while keeping one JetStream cursor" do
    config =
      config(
        consumer_name: "analysis-scaling-test",
        processor_concurrency: 12,
        batch_size: 25,
        batch_timeout: 250
      )

    options = Pipeline.broadway_options(config)

    assert options[:name] == Pipeline
    assert options[:context] == config
    assert get_in(options, [:producer, :concurrency]) == 1
    assert get_in(options, [:processors, :default, :concurrency]) == 12

    assert {ServiceRadar.EventWriter.Producer, producer_config} =
             get_in(options, [:producer, :module])

    assert producer_config.consumer_name == "analysis-scaling-test"
    assert producer_config.batch_size == 25
    assert producer_config.batch_timeout == 250
    assert producer_config.streams == config.streams
  end

  test "extracts enabled samples and invokes the reasoner" do
    message = message("metrics.sysmon.memory", sysmon_envelope("memory"))
    config = config(enabled_subjects: ["metrics.sysmon.*"])

    assert ^message = Pipeline.handle_message(:default, message, config)

    assert_receive {:evaluate, sample}
    assert sample.value == 50.0
    assert is_binary(sample.event_id)
    assert is_tuple(sample.order_key)
    refute_receive {:emit_anomaly_verdict, _sample, _verdict}
  end

  test "emits confirmed anomaly verdicts through the causal prediction emitter" do
    Application.put_env(
      :serviceradar_core,
      :anomaly_detection_context_engine,
      __MODULE__.AnomalousContextEngine
    )

    Application.put_env(
      :serviceradar_core,
      :anomaly_detection_verdict_emitter,
      __MODULE__.VerdictEmitterStub
    )

    message = message("metrics.sysmon.memory", sysmon_envelope("memory"))
    config = config(enabled_subjects: ["metrics.sysmon.*"])

    assert ^message = Pipeline.handle_message(:default, message, config)

    assert_receive {:emit_anomaly_verdict, sample, verdict}
    assert sample.series_key == "sysmon:memory:host-1"
    assert verdict.anomalous == true
    assert verdict.state == "anomalous"
  end

  test "emits a clearing verdict when an active anomaly returns to normal" do
    Application.put_env(
      :serviceradar_core,
      :anomaly_detection_context_engine,
      __MODULE__.AnomalousContextEngine
    )

    Application.put_env(
      :serviceradar_core,
      :anomaly_detection_verdict_emitter,
      __MODULE__.VerdictEmitterStub
    )

    message = message("metrics.sysmon.memory", sysmon_envelope("memory"))
    config = config(enabled_subjects: ["metrics.sysmon.*"])

    assert ^message = Pipeline.handle_message(:default, message, config)
    assert_receive {:emit_anomaly_verdict, %{series_key: "sysmon:memory:host-1"}, active_verdict}
    assert active_verdict.anomalous == true

    Application.put_env(
      :serviceradar_core,
      :anomaly_detection_context_engine,
      __MODULE__.NormalContextEngine
    )

    assert ^message = Pipeline.handle_message(:default, message, config)
    assert_receive {:emit_anomaly_verdict, %{series_key: "sysmon:memory:host-1"}, clear_verdict}
    assert clear_verdict.anomalous == false
    assert clear_verdict.state == "normal"

    assert ^message = Pipeline.handle_message(:default, message, config)
    refute_receive {:emit_anomaly_verdict, _sample, _verdict}
  end

  test "emits one clearing verdict after restart when normal evidence arrives" do
    Application.put_env(
      :serviceradar_core,
      :anomaly_detection_context_engine,
      __MODULE__.AnomalousContextEngine
    )

    Application.put_env(
      :serviceradar_core,
      :anomaly_detection_verdict_emitter,
      __MODULE__.VerdictEmitterStub
    )

    message = message("metrics.sysmon.memory", sysmon_envelope("memory"))
    config = config(enabled_subjects: ["metrics.sysmon.*"])

    assert ^message = Pipeline.handle_message(:default, message, config)
    assert_receive {:emit_anomaly_verdict, %{series_key: "sysmon:memory:host-1"}, active_verdict}
    assert active_verdict.anomalous == true

    Pipeline.reset_active_series_for_test()

    Application.put_env(
      :serviceradar_core,
      :anomaly_detection_context_engine,
      __MODULE__.NormalContextEngine
    )

    assert ^message = Pipeline.handle_message(:default, message, config)
    assert_receive {:emit_anomaly_verdict, %{series_key: "sysmon:memory:host-1"}, clear_verdict}
    assert clear_verdict.anomalous == false
    assert clear_verdict.state == "normal"

    assert ^message = Pipeline.handle_message(:default, message, config)
    refute_receive {:emit_anomaly_verdict, _sample, _verdict}
  end

  test "marks messages failed when anomaly verdict emission fails" do
    Application.put_env(
      :serviceradar_core,
      :anomaly_detection_context_engine,
      __MODULE__.AnomalousContextEngine
    )

    Application.put_env(
      :serviceradar_core,
      :anomaly_detection_verdict_emitter,
      __MODULE__.FailingVerdictEmitter
    )

    message = message("metrics.sysmon.memory", sysmon_envelope("memory"))
    config = config(enabled_subjects: ["metrics.sysmon.*"])

    assert %Message{status: {:failed, {:anomaly_verdict_emit_failed, :nats_down}}} =
             Pipeline.handle_message(:default, message, config)
  end

  test "marks messages failed when the reasoner returns an error" do
    Application.put_env(
      :serviceradar_core,
      :anomaly_detection_context_engine,
      __MODULE__.FailingContextEngine
    )

    message = message("metrics.sysmon.memory", sysmon_envelope("memory"))
    config = config(enabled_subjects: ["metrics.sysmon.*"])

    assert %Message{status: {:failed, "bad sample"}} =
             Pipeline.handle_message(:default, message, config)
  end

  test "ack invokes ack and nack callbacks" do
    parent = self()

    message = %Message{
      data: "",
      metadata: %{subject: "otel.metrics.derived", reply_to: "$JS.ACK.analysis"},
      acknowledger:
        {Pipeline, :ack_ref,
         %{
           ack_fun: fn
             :ack ->
               send(parent, :acked)
               :ok

             :nack ->
               send(parent, :nacked)
               :ok
           end
         }}
    }

    assert :ok == Pipeline.ack(:ack_ref, [message], [message])
    assert_receive :acked
    assert_receive :nacked
  end

  defmodule ContextEngineStub do
    @moduledoc false
    def evaluate(sample) do
      send(Application.fetch_env!(:serviceradar_core, :anomaly_detection_pipeline_test_pid), {
        :evaluate,
        sample
      })

      {:ok, %{state: "insufficient_baseline", anomalous: false}}
    end
  end

  defmodule AnomalousContextEngine do
    @moduledoc false

    def evaluate(sample) do
      send(Application.fetch_env!(:serviceradar_core, :anomaly_detection_pipeline_test_pid), {
        :evaluate,
        sample
      })

      {:ok,
       %{
         state: "anomalous",
         anomalous: true,
         breached: true,
         include_in_baseline: false,
         next_consecutive_anomalous: 5,
         score: 3.5,
         reason: "rolling z-score breached",
         baseline_count: 48,
         sample_value: sample.value,
         observed_at_unix_nano: sample.observed_at_unix_nano,
         signals: []
       }}
    end
  end

  defmodule NormalContextEngine do
    @moduledoc false

    def evaluate(sample) do
      send(Application.fetch_env!(:serviceradar_core, :anomaly_detection_pipeline_test_pid), {
        :evaluate,
        sample
      })

      {:ok,
       %{
         state: "normal",
         anomalous: false,
         breached: false,
         include_in_baseline: true,
         score: 0.2,
         reason: "back inside baseline",
         baseline_count: 49,
         sample_value: sample.value,
         observed_at_unix_nano: sample.observed_at_unix_nano,
         signals: []
       }}
    end
  end

  defmodule FailingContextEngine do
    @moduledoc false
    def evaluate(_sample), do: {:error, "bad sample"}
  end

  defmodule VerdictEmitterStub do
    @moduledoc false

    def emit(sample, verdict) do
      send(Application.fetch_env!(:serviceradar_core, :anomaly_detection_pipeline_test_pid), {
        :emit_anomaly_verdict,
        sample,
        verdict
      })

      :ok
    end
  end

  defmodule FailingVerdictEmitter do
    @moduledoc false
    def emit(_sample, _verdict), do: {:error, :nats_down}
  end

  defp config(opts) do
    struct!(
      Config,
      Keyword.merge(
        [
          enabled: true,
          nats: %{},
          batch_size: 100,
          batch_timeout: 1_000,
          consumer_name: "analysis-test",
          producer_name: ServiceRadar.Observability.AnomalyDetection.Producer,
          processor_concurrency: 1,
          enabled_subjects: ["otel.metrics.>"],
          streams: Config.default_streams()
        ],
        opts
      )
    )
  end

  defp message(subject, payload) do
    %Message{
      data: Jason.encode!(payload),
      metadata: %{subject: subject, reply_to: "$JS.ACK.test"},
      acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
    }
  end

  defp sysmon_envelope(family) do
    %{
      "schema" => "serviceradar.sysmon.metrics.v1",
      "source" => "sysmon-metrics",
      "metric_family" => family,
      "agent_id" => "agent-1",
      "gateway_id" => "gateway-1",
      "partition" => "default",
      "sample" => %{
        "timestamp" => "2026-06-12T00:00:00Z",
        "host_id" => "host-1",
        "agent_id" => "agent-1",
        "memory" => %{"used_bytes" => 50, "total_bytes" => 100}
      }
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
