defmodule ServiceRadar.Events.AuditWriterTest do
  @moduledoc """
  Integration coverage for audit event writes.

  In the tenant-instance architecture, tests run against the single schema
  determined by PostgreSQL search_path.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "writes audit events with UUID fields" do
    resource_id = Ecto.UUID.generate()

    assert :ok =
             AuditWriter.write(
               action: :create,
               resource_type: "integration_source",
               resource_id: resource_id,
               resource_name: "source-1",
               actor: %{id: "user-1", email: "user@example.com"},
               details: %{endpoint: "https://example.net"}
             )

    # Query against the current schema (determined by search_path)
    assert %Postgrex.Result{rows: [[count]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT COUNT(*) FROM ocsf_events",
               []
             )

    assert count > 0
  end
end
