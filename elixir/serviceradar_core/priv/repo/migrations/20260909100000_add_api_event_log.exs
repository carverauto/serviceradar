defmodule ServiceRadar.Repo.Migrations.AddApiEventLog do
  @moduledoc """
  Backs the `add-ash-events-audit-log` OpenSpec change.

  Creates the `api_events` table in the `platform` schema for
  `ServiceRadar.Observability.ApiEvent` (an `AshEvents.EventLog` resource):
  a single, centralized, actor-keyed event log that
  `ServiceRadar.Observability.StatefulAlertRule` (via `AshEvents.Events`)
  records its create/update/destroy actions into.

  Hand-written `use Ecto.Migration` matching the existing pattern in this
  directory (e.g. `20260512040000_add_security_resources.exs`). The
  `mix ash.codegen` workflow is currently blocked on gitignored resource
  snapshots (see that migration's moduledoc and
  `docs/PLATFORM_SECURITY_HARDENING.md#known-follow-ups`, tracked as
  Forgejo issue #3269 / GitHub issue #3456); reworking that path is out of
  scope for this change.

  Idempotent: every CREATE uses `IF NOT EXISTS` so the migration is safe to
  re-run against a partially-applied database.
  """
  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"")

    create_if_not_exists table(:api_events, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:record_id, :uuid, null: false)
      add(:version, :bigint, null: false, default: 1)
      add(:occurred_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:resource, :text, null: false)
      add(:action, :text, null: false)
      add(:action_type, :text, null: false)
      add(:metadata, :map, null: false, default: %{})
      add(:data, :map, null: false, default: %{})
      add(:changed_attributes, :map, null: false, default: %{})
      # Persisted actor primary key (AshEvents `persist_actor_primary_key
      # :user_id, ServiceRadar.Identity.User`). No FK: AshEvents adds this as
      # a bare attribute, not a `belongs_to` relationship, and events must
      # outlive a deleted user.
      add(:user_id, :uuid)
    end

    # BRIN on occurred_at is the right shape for an append-only event log,
    # matching security_events' index.
    execute(
      "CREATE INDEX IF NOT EXISTS api_events_occurred_at_brin_index ON #{@prefix}.api_events USING BRIN (occurred_at)"
    )

    create_if_not_exists(
      index(:api_events, [:resource, :occurred_at],
        name: :api_events_resource_occurred_at_index,
        prefix: @prefix
      )
    )

    create_if_not_exists(
      index(:api_events, [:user_id, :occurred_at],
        name: :api_events_user_id_occurred_at_index,
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(table(:api_events, prefix: @prefix))
  end
end
