defmodule ServiceRadar.Observability.AnomalyDetection.PipelineTest do
  use ExUnit.Case, async: false

  alias Broadway.Message
  alias ServiceRadar.Observability.AnomalyDetection.Config
  alias ServiceRadar.Observability.AnomalyDetection.Pipeline

  setup do
    previous_reasoner = Application.get_env(:serviceradar_core, :anomaly_detection_reasoner)
    previous_pid = Application.get_env(:serviceradar_core, :anomaly_detection_pipeline_test_pid)

    Application.put_env(:serviceradar_core, :anomaly_detection_reasoner, __MODULE__.ReasonerStub)
    Application.put_env(:serviceradar_core, :anomaly_detection_pipeline_test_pid, self())

    on_exit(fn ->
      restore_env(:anomaly_detection_reasoner, previous_reasoner)
      restore_env(:anomaly_detection_pipeline_test_pid, previous_pid)
    end)

    :ok
  end

  test "acks disabled subjects without invoking the reasoner" do
    message = message("metrics.sysmon.memory", sysmon_envelope("memory"))
    config = config(enabled_subjects: ["otel.metrics.>"])

    assert ^message = Pipeline.handle_message(:default, message, config)
    refute_receive {:reason, _context, _sample}
  end

  test "extracts enabled samples and invokes the reasoner" do
    message = message("metrics.sysmon.memory", sysmon_envelope("memory"))
    config = config(enabled_subjects: ["metrics.sysmon.*"])

    assert ^message = Pipeline.handle_message(:default, message, config)

    assert_receive {:reason, context, sample}
    assert context.baseline == []
    assert context.confirm_slots == 5
    assert sample.value == 50.0
  end

  test "marks messages failed when the reasoner returns an error" do
    Application.put_env(
      :serviceradar_core,
      :anomaly_detection_reasoner,
      __MODULE__.FailingReasoner
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

  defmodule ReasonerStub do
    @moduledoc false
    def reason(context, sample) do
      send(Application.fetch_env!(:serviceradar_core, :anomaly_detection_pipeline_test_pid), {
        :reason,
        context,
        sample
      })

      {:ok, %{state: "insufficient_baseline", anomalous: false}}
    end
  end

  defmodule FailingReasoner do
    @moduledoc false
    def reason(_context, _sample), do: {:error, "bad sample"}
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
