defmodule ServiceRadar.Events.AuditWriterTest do
  @moduledoc """
  Integration coverage for audit event writes.

  In the single-deployment architecture, tests run against the single schema
  determined by PostgreSQL search_path.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.MetricContract

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "builds audit events with UUID fields" do
    resource_id = Ecto.UUID.generate()

    assert {:ok, event} =
             AuditWriter.build_event(
               action: :create,
               resource_type: "integration_source",
               resource_id: resource_id,
               resource_name: "source-1",
               actor: %{id: "user-1", email: "user@example.com"},
               details: %{endpoint: "https://example.net"}
             )

    assert {:ok, _} = Ecto.UUID.dump(event.id)
    assert metadata_value(event.metadata, :correlation_uid) == "integration_source:#{resource_id}"
    assert event.log_name == "integration_source"
    assert Enum.any?(event.observables, &(&1.name == resource_id))
  end

  test "counts an audit record it could not publish on an exported metric" do
    event = [:serviceradar, :audit, :publish_failed]
    parent = self()
    handler = "audit-writer-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn ^event, measurements, metadata, _config ->
          if self() == parent, do: send(parent, {:publish_failed, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:error, {:missing_required, :action}} =
             AuditWriter.write(resource_type: "agent_certificate", resource_id: "agent-1")

    assert_received {:publish_failed, measurements, metadata}
    assert metadata.resource_type == "agent_certificate"
    MetricContract.assert_exported(event, measurements, metadata)
  end

  defp metadata_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end
end
