defmodule ServiceRadar.Repo.Migrations.AddCredentialBrokerRetentionIndexes do
  @moduledoc """
  Indexes supporting `ServiceRadar.Credentials.BrokerRetentionWorker`.

  None of these four tables could answer "which rows are older than X" without a
  sequential scan. `credential_broker_grants` indexed `expires_at` only as the
  third column of `(agent_id, status, expires_at)`, which a bare age predicate
  cannot use, and neither `_versions` table indexed `version_inserted_at` at all.

  A retention job without a supporting index is how a prune quietly stops keeping
  up with its table -- it is not a nicety here, it is what makes the job bounded.
  """

  use Ecto.Migration

  # Concurrent index builds cannot run inside a transaction, and these tables are
  # large (~460k rows each on demo) and written continuously by credential
  # brokerage. Blocking writes to take a lock would stall credential issuance.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:credential_broker_grants, [:expires_at],
        prefix: "platform",
        name: "credential_broker_grants_expires_at_idx",
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:credential_broker_grant_versions, [:version_inserted_at],
        prefix: "platform",
        name: "credential_broker_grant_versions_inserted_at_idx",
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:credential_secret_resolution_audits, [:occurred_at],
        prefix: "platform",
        name: "credential_secret_resolution_audits_occurred_at_idx",
        concurrently: true
      )
    )

    create_if_not_exists(
      index(
        :credential_secret_resolution_audit_versions,
        [:version_inserted_at],
        prefix: "platform",
        name: "credential_secret_resolution_audit_versions_inserted_at_idx",
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:credential_broker_grants, [:expires_at],
        prefix: "platform",
        name: "credential_broker_grants_expires_at_idx",
        concurrently: true
      )
    )

    drop_if_exists(
      index(:credential_broker_grant_versions, [:version_inserted_at],
        prefix: "platform",
        name: "credential_broker_grant_versions_inserted_at_idx",
        concurrently: true
      )
    )

    drop_if_exists(
      index(:credential_secret_resolution_audits, [:occurred_at],
        prefix: "platform",
        name: "credential_secret_resolution_audits_occurred_at_idx",
        concurrently: true
      )
    )

    drop_if_exists(
      index(
        :credential_secret_resolution_audit_versions,
        [:version_inserted_at],
        prefix: "platform",
        name: "credential_secret_resolution_audit_versions_inserted_at_idx",
        concurrently: true
      )
    )
  end
end
