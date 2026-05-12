defmodule ServiceRadar.Repo.Migrations.AddSecurityResources do
  @moduledoc """
  Backs the `add-platform-security-hardening` OpenSpec change.

  Creates the two new Ash resources in the `platform` schema:

    * `security_events` — append-only stream of stateless security
      events recorded by `ServiceRadar.Security.Events`.
    * `auth_lockouts` (+ AshPaperTrail versions) — account-level
      lockouts created by `ServiceRadar.Security.Lockouts`.

  Hand-written `use Ecto.Migration` matching the existing pattern in
  this directory (e.g. `20260117090000_rebuild_schema.exs`). The
  `mix ash.codegen` workflow is currently blocked on gitignored
  resource snapshots; reworking that path is tracked separately in
  Forgejo issue #3269.

  Idempotent: every CREATE uses `IF NOT EXISTS` so the migration is
  safe to re-run against a partially-applied database.
  """
  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"")

    create_if_not_exists table(:security_events, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:occurred_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:kind, :text, null: false)
      add(:severity, :text, null: false, default: "info")
      add(:actor_id, :text)
      add(:ip, :text)
      add(:route, :text)
      add(:details, :map, null: false, default: %{})
      add(:correlation_id, :text)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    # BRIN on occurred_at is the right shape for an append-only event log.
    execute(
      "CREATE INDEX IF NOT EXISTS security_events_occurred_at_brin_index ON #{@prefix}.security_events USING BRIN (occurred_at)"
    )

    create_if_not_exists(
      index(:security_events, [:kind, :occurred_at],
        name: :security_events_kind_occurred_at_index,
        prefix: @prefix
      )
    )

    create_if_not_exists table(:auth_lockouts, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:actor_id, :text, null: false)
      add(:locked_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:locked_by, :text)
      add(:reason, :text)
      add(:expires_at, :utc_datetime_usec)
      add(:cleared_at, :utc_datetime_usec)
      add(:cleared_by, :text)
      add(:clear_reason, :text)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create_if_not_exists(index(:auth_lockouts, [:actor_id], prefix: @prefix))
    create_if_not_exists(index(:auth_lockouts, [:cleared_at], prefix: @prefix))

    create_if_not_exists table(:auth_lockout_versions, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:version_action_inputs, :map, null: false, default: %{})
      add(:version_source_id, :uuid, null: false)
      add(:changes, :map, null: false, default: %{})
      add(:version_inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:version_updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create_if_not_exists(
      index(:auth_lockout_versions, [:version_source_id], prefix: @prefix)
    )
  end

  def down do
    drop_if_exists(table(:auth_lockout_versions, prefix: @prefix))
    drop_if_exists(table(:auth_lockouts, prefix: @prefix))
    drop_if_exists(table(:security_events, prefix: @prefix))
  end
end
