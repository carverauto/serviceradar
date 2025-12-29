defmodule ServiceRadar.Repo.Migrations.AddOcsfEvents do
  @moduledoc """
  Creates the ocsf_events hypertable for storing OCSF-formatted events.

  This table follows the OCSF v1.7.0 base event schema with fields
  for Event Log Activity (class_uid: 1008) in System Activity category.

  ## OCSF Fields

  - class_uid: 1008 (Event Log Activity)
  - category_uid: 1 (System Activity)
  - activity_id: 1=Create, 2=Read, 3=Update, 4=Delete, etc.
  - severity_id: 0=Unknown, 1=Informational, 2=Low, 3=Medium, 4=High, 5=Critical, 6=Fatal
  """

  use Ecto.Migration

  def up do
    # Create the ocsf_events table
    create table(:ocsf_events, primary_key: false) do
      # Primary key is (time, id) for TimescaleDB hypertable
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()")
      add :time, :utc_datetime_usec, null: false

      # OCSF Classification Fields (required)
      add :class_uid, :integer, null: false, default: 1008
      add :category_uid, :integer, null: false, default: 1
      add :type_uid, :bigint, null: false
      add :activity_id, :integer, null: false, default: 1
      add :severity_id, :integer, null: false, default: 1

      # OCSF Content Fields
      add :message, :text
      add :severity, :text
      add :activity_name, :text

      # OCSF Status Fields
      add :status_id, :integer
      add :status, :text
      add :status_code, :text
      add :status_detail, :text

      # OCSF Metadata (required object)
      add :metadata, :map, null: false, default: %{}

      # OCSF Observables (array of observable objects)
      add :observables, {:array, :map}, default: []

      # OpenTelemetry trace context (for correlation)
      add :trace_id, :text
      add :span_id, :text

      # Actor/Source information
      add :actor, :map, default: %{}
      add :device, :map, default: %{}
      add :src_endpoint, :map, default: %{}

      # Log-specific fields
      add :log_name, :text
      add :log_provider, :text
      add :log_level, :text
      add :log_version, :text

      # Unmapped data for extensibility
      add :unmapped, :map, default: %{}

      # Raw data for debugging/replay
      add :raw_data, :text

      # Multi-tenancy
      add :tenant_id, :uuid, null: false

      # Record timestamp
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    # Create TimescaleDB hypertable for efficient time-series queries
    execute """
    SELECT create_hypertable('ocsf_events', 'time',
      chunk_time_interval => INTERVAL '1 day',
      if_not_exists => TRUE)
    """

    # Create indexes for common query patterns
    create index(:ocsf_events, [:tenant_id, :time])
    create index(:ocsf_events, [:class_uid])
    create index(:ocsf_events, [:category_uid])
    create index(:ocsf_events, [:severity_id])
    create index(:ocsf_events, [:trace_id], where: "trace_id IS NOT NULL")
    create index(:ocsf_events, [:log_name], where: "log_name IS NOT NULL")

    # GIN index for metadata queries
    execute "CREATE INDEX ocsf_events_metadata_idx ON ocsf_events USING gin (metadata)"
  end

  def down do
    drop table(:ocsf_events)
  end
end
