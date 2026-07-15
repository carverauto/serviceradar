defmodule ServiceRadar.Repo.Migrations.SplitAnsibleControllerCredentialsByPurpose do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:ansible_controllers, prefix: @prefix) do
      add(:sync_credential_secret_id, :uuid)
      add(:execution_credential_secret_id, :uuid)
      add(:callback_credential_secret_id, :uuid)
    end

    # Existing controllers used the legacy token for every verb. Copying that
    # exact reference into each purpose preserves (but does not expand) their
    # pre-upgrade authority. Operators can then rotate each purpose to a
    # narrower AWX principal without interrupting inventory or active jobs.
    execute("""
    UPDATE #{@prefix}.ansible_controllers
    SET sync_credential_secret_id = credential_secret_id,
        execution_credential_secret_id = credential_secret_id,
        callback_credential_secret_id = credential_secret_id
    WHERE sync_credential_secret_id IS NULL
       OR execution_credential_secret_id IS NULL
       OR callback_credential_secret_id IS NULL
    """)

    execute(
      "COMMENT ON COLUMN #{@prefix}.ansible_controllers.credential_secret_id IS " <>
        "'DEPRECATED: one-release rolling-upgrade mirror/fallback for sync only'"
    )

    execute(
      "COMMENT ON COLUMN #{@prefix}.ansible_controllers.sync_credential_secret_id IS " <>
        "'AWX token reference for health, catalog, and inventory reads'"
    )

    execute(
      "COMMENT ON COLUMN #{@prefix}.ansible_controllers.execution_credential_secret_id IS " <>
        "'AWX token reference for launch, job observation, reconciliation, and cancellation'"
    )

    execute(
      "COMMENT ON COLUMN #{@prefix}.ansible_controllers.callback_credential_secret_id IS " <>
        "'AWX token reference for reviewed ephemeral callback credential lifecycle'"
    )
  end

  def down do
    alter table(:ansible_controllers, prefix: @prefix) do
      remove(:callback_credential_secret_id)
      remove(:execution_credential_secret_id)
      remove(:sync_credential_secret_id)
    end

    execute("COMMENT ON COLUMN #{@prefix}.ansible_controllers.credential_secret_id IS NULL")
  end
end
