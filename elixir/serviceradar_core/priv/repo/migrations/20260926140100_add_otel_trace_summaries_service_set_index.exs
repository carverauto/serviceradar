defmodule ServiceRadar.Repo.Migrations.AddOtelTraceSummariesServiceSetIndex do
  @moduledoc """
  GIN index on `platform.otel_trace_summaries.service_set` for the participating-service
  filter: SRQL compiles `in:otel_trace_summaries service_name:X` to
  `service_set @> ARRAY[X]` and the list form to `service_set && ARRAY[...]`, and both
  operators are served by the default array GIN operator class.

  `otel_trace_summaries` is a plain table (not a hypertable) that
  `RefreshTraceSummariesWorker` upserts every couple of minutes, so the index is built
  `CONCURRENTLY` to avoid blocking those writes. That cannot run inside a transaction,
  hence a migration of its own with the DDL transaction and migration lock disabled.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:otel_trace_summaries, [:service_set],
        prefix: "platform",
        name: "idx_trace_summaries_service_set_gin",
        using: "GIN",
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:otel_trace_summaries, [:service_set],
        prefix: "platform",
        name: "idx_trace_summaries_service_set_gin",
        concurrently: true
      )
    )
  end
end
