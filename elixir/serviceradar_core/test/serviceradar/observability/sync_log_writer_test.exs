defmodule ServiceRadar.Observability.SyncLogWriterTest do
  @moduledoc """
  In the single-deployment architecture, tests run against the single schema
  determined by PostgreSQL search_path.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Monitoring.OcsfEvent
  alias ServiceRadar.Observability.Log
  alias ServiceRadar.Observability.SyncLogWriter
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = %{id: "system", role: :admin}
    {:ok, actor: actor}
  end

  test "writes sync lifecycle logs without creating OCSF events", %{
    actor: actor
  } do
    source = %IntegrationSource{
      id: Ash.UUID.generate(),
      name: "Armis",
      source_type: :armis,
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default"
    }

    assert :ok = SyncLogWriter.write_start(source, device_count: 3)

    assert :ok =
             SyncLogWriter.write_finish(source,
               result: :failed,
               device_count: 3,
               error_message: "boom"
             )

    logs =
      Log
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.read(actor: actor)
      |> Page.unwrap!()

    sync_logs =
      Enum.filter(logs, fn log ->
        attributes = Jason.decode!(log.attributes || "{}")

        get_in(attributes, ["serviceradar", "sync", "integration_source_id"]) ==
          to_string(source.id)
      end)

    assert Enum.any?(sync_logs, fn log ->
             attributes = Jason.decode!(log.attributes || "{}")
             get_in(attributes, ["serviceradar", "sync", "stage"]) == "started"
           end)

    assert Enum.any?(sync_logs, fn log ->
             attributes = Jason.decode!(log.attributes || "{}")

             get_in(attributes, ["serviceradar", "sync", "stage"]) == "finished" and
               get_in(attributes, ["serviceradar", "sync", "result"]) == "failed" and
               get_in(attributes, ["serviceradar", "sync", "error_message"]) == "boom"
           end)

    events =
      OcsfEvent
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.read(actor: actor)
      |> Page.unwrap!()

    sync_events =
      Enum.filter(events, fn event ->
        get_in(event.unmapped || %{}, [
          "log_attributes",
          "serviceradar",
          "sync",
          "integration_source_id"
        ]) ==
          to_string(source.id)
      end)

    assert sync_events == []
  end
end
