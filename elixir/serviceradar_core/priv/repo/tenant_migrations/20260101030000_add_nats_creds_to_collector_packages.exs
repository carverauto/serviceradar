defmodule ServiceRadar.Repo.Migrations.AddNatsCredsToCollectorPackages do
  @moduledoc """
  Adds encrypted NATS credentials storage to collector_packages table.

  This allows the package download endpoint to return the actual .creds file
  content that collectors need to authenticate with NATS.
  """

  use Ecto.Migration

  def up do
    alter table(:collector_packages) do
      # Encrypted NATS credentials file content (AshCloak stores as encrypted_nats_creds_ciphertext)
      add :encrypted_nats_creds_ciphertext, :binary
    end
  end

  def down do
    alter table(:collector_packages) do
      remove :encrypted_nats_creds_ciphertext
    end
  end
end
