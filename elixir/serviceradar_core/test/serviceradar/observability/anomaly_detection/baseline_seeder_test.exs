defmodule ServiceRadar.Observability.AnomalyDetection.BaselineSeederTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.AnomalyDetection.BaselineSeeder

  test "renders configured SRQL templates and extracts numeric CAGG values" do
    assert {:ok, [8.0, 9.5]} =
             BaselineSeeder.seed(sample(),
               enabled: true,
               runner: __MODULE__.Runner,
               runner_opts: [test_pid: self()],
               query_templates: %{
                 "sysmon.cpu" =>
                   ~s(in:cpu_metrics device_id:"{{metadata.device_id}}" series:"{{series_key}}" time:last_7d)
               },
               reverse_rows: false
             )

    assert_received {:seed_query,
                     ~s(in:cpu_metrics device_id:"device-1" series:"sysmon:cpu:device-1:all" time:last_7d)}
  end

  defmodule Runner do
    @moduledoc false
    def query(query, opts) do
      opts
      |> Keyword.fetch!(:test_pid)
      |> send({:seed_query, query})

      {:ok, [%{"avg_usage_percent" => 8}, %{"avg_usage_percent" => "9.5"}]}
    end
  end

  defp sample do
    %{
      series_key: "sysmon:cpu:device-1:all",
      subject: "metrics.sysmon.cpu",
      metric_class: "sysmon.cpu",
      metadata: %{"device_id" => "device-1"}
    }
  end
end
