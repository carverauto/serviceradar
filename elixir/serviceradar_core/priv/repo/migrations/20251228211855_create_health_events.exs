defmodule ServiceRadar.Repo.Migrations.CreateHealthEvents do
  @moduledoc """
  Creates the health_events table for tracking health state changes
  across all infrastructure entities (pollers, agents, checkers, etc.).
  """

  use Ecto.Migration

  def up do
    create table(:health_events, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :entity_type, :string, null: false
      add :entity_id, :string, null: false
      add :old_state, :string
      add :new_state, :string, null: false
      add :reason, :string
      add :node, :string
      add :duration_seconds, :integer
      add :recorded_at, :utc_datetime, null: false
      add :metadata, :map, default: %{}
      add :tenant_id, :uuid, null: false
    end

    # Primary query pattern: entity timeline
    create index(:health_events, [:entity_type, :entity_id, :recorded_at])

    # Tenant-scoped queries
    create index(:health_events, [:tenant_id, :recorded_at])

    # State-based queries (e.g., find all offline entities)
    create index(:health_events, [:entity_type, :new_state, :recorded_at])

    # Tenant + entity combo for multi-tenant lookups
    create index(:health_events, [:tenant_id, :entity_type, :entity_id])
  end

  def down do
    drop table(:health_events)
  end
end
