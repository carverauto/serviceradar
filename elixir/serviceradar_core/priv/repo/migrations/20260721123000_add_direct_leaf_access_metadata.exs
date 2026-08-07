defmodule ServiceRadar.Repo.Migrations.AddDirectLeafAccessMetadata do
  @moduledoc false

  use Ecto.Migration

  def up do
    alter table(:addon_assignments, prefix: "platform") do
      add(:direct_subject_scope, :map, null: false, default: %{})
      add(:direct_access_status, :text, null: false, default: "not_requested")
      add(:direct_access_generation, :bigint, null: false, default: 0)
      add(:direct_access_expires_at, :utc_datetime_usec)
      add(:direct_access_revoked_at, :utc_datetime_usec)
      add(:direct_access_error, :text)
      add(:direct_certificate_pem_ciphertext, :binary)
      add(:direct_private_key_pem_ciphertext, :binary)
      add(:direct_ca_chain_pem_ciphertext, :binary)
      add(:direct_certificate_fingerprint, :text)
      add(:direct_identity_component_id, :text)
      add(:direct_identity_partition_id, :text)
    end

    create(index(:addon_assignments, [:direct_access_status], prefix: "platform"))
  end

  def down do
    drop_if_exists(index(:addon_assignments, [:direct_access_status], prefix: "platform"))

    alter table(:addon_assignments, prefix: "platform") do
      remove(:direct_identity_partition_id)
      remove(:direct_identity_component_id)
      remove(:direct_certificate_fingerprint)
      remove(:direct_ca_chain_pem_ciphertext)
      remove(:direct_private_key_pem_ciphertext)
      remove(:direct_certificate_pem_ciphertext)
      remove(:direct_access_error)
      remove(:direct_access_revoked_at)
      remove(:direct_access_expires_at)
      remove(:direct_access_generation)
      remove(:direct_access_status)
      remove(:direct_subject_scope)
    end
  end
end
