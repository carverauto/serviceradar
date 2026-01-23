defmodule ServiceRadar.Observability.SnmpMetricsIngestorIntegrationTest do
  @moduledoc """
  Integration coverage for SNMP metrics ingestion through ResultsRouter.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.TimeseriesMetric
  alias ServiceRadar.ResultsRouter
  alias ServiceRadar.TestSupport

  require Ash.Query

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "snmp metrics flow through ResultsRouter" do
    actor = SystemActor.system(:test)
    agent_id = "test-agent-#{System.unique_integer([:positive])}"
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    payload = %{
      "results" => [
        %{
          "timestamp" => timestamp,
          "metric" => "ifInOctets",
          "value" => 123.0,
          "target" => "192.0.2.10",
          "interface_uid" => "ifindex:3",
          "oid" => ".1.3.6.1.2.1.31.1.1.1.6.3",
          "scale" => 1.0,
          "delta" => true
        }
      ]
    }

    status = %{
      source: "snmp-metrics",
      service_type: "snmp",
      service_name: "snmp",
      message: Jason.encode!(payload),
      agent_id: agent_id,
      gateway_id: "test-gateway",
      partition: "default",
      timestamp: DateTime.utc_now()
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})

    query =
      TimeseriesMetric
      |> Ash.Query.filter(
        agent_id == ^agent_id and metric_type == "snmp" and metric_name == "ifInOctets"
      )

    assert {:ok, metrics} = Ash.read(query, actor: actor)
    assert Enum.any?(metrics)
  end

  test "snmp metrics normalize interface uid and metric name" do
    actor = SystemActor.system(:test)
    agent_id = "test-agent-#{System.unique_integer([:positive])}"
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    payload = %{
      "results" => [
        %{
          "timestamp" => timestamp,
          "metric" => "ifInErrors::ifindex:3",
          "value" => 0,
          "target" => "192.0.2.11",
          "interface_uid" => "ifindex:3"
        }
      ]
    }

    status = %{
      source: "snmp-metrics",
      service_type: "snmp",
      service_name: "snmp",
      message: Jason.encode!(payload),
      agent_id: agent_id,
      gateway_id: "test-gateway",
      partition: "default",
      timestamp: DateTime.utc_now()
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})

    query =
      TimeseriesMetric
      |> Ash.Query.filter(metric_name == "ifInErrors" and if_index == 3)

    assert {:ok, metrics} = Ash.read(query, actor: actor)
    assert Enum.any?(metrics)
  end
end
