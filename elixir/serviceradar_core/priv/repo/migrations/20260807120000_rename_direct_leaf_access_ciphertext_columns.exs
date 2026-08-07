defmodule ServiceRadar.Repo.Migrations.RenameDirectLeafAccessCiphertextColumns do
  @moduledoc """
  Renames the three direct-leaf-access ciphertext columns to the names AshCloak actually reads.

  20260721123000_add_direct_leaf_access_metadata created `direct_certificate_pem_ciphertext`,
  `direct_private_key_pem_ciphertext` and `direct_ca_chain_pem_ciphertext`. Those names never
  matched the resource: AshCloak removes each attribute named in a `cloak` block and stores it
  as `encrypted_<name>`, so with the attributes then suffixed `_ciphertext` the storage columns
  it looked for were `encrypted_direct_certificate_pem_ciphertext` and friends.

  Nothing could read the table as a result -- every query on addon_assignments selects all
  attributes, so all of them failed with

      ERROR 42703 (undefined_column)
      column a0.encrypted_direct_ca_chain_pem_ciphertext does not exist

  ServiceRadar.Plugins.AddonAssignment now declares the attributes under their plaintext names,
  which makes the columns `encrypted_direct_certificate_pem` and friends.

  No data migration is needed, and no data can be lost: the write path failed for the same
  reason the read path did, so these columns are empty everywhere. They hold encrypted PEM
  material, and a rename preserves the bytes regardless.
  """

  use Ecto.Migration

  def up do
    rename(
      table(:addon_assignments, prefix: "platform"),
      :direct_certificate_pem_ciphertext,
      to: :encrypted_direct_certificate_pem
    )

    rename(
      table(:addon_assignments, prefix: "platform"),
      :direct_private_key_pem_ciphertext,
      to: :encrypted_direct_private_key_pem
    )

    rename(
      table(:addon_assignments, prefix: "platform"),
      :direct_ca_chain_pem_ciphertext,
      to: :encrypted_direct_ca_chain_pem
    )
  end

  def down do
    rename(
      table(:addon_assignments, prefix: "platform"),
      :encrypted_direct_ca_chain_pem,
      to: :direct_ca_chain_pem_ciphertext
    )

    rename(
      table(:addon_assignments, prefix: "platform"),
      :encrypted_direct_private_key_pem,
      to: :direct_private_key_pem_ciphertext
    )

    rename(
      table(:addon_assignments, prefix: "platform"),
      :encrypted_direct_certificate_pem,
      to: :direct_certificate_pem_ciphertext
    )
  end
end
