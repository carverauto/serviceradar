defmodule ServiceRadar.Repo.Migrations.AddSystemAccountSeedToNatsOperators do
  @moduledoc """
  Add encrypted system account seed column to nats_operators.

  AshCloak encrypts the system_account_seed_ciphertext attribute and stores it
  with an 'encrypted_' prefix in the database.
  """

  use Ecto.Migration

  def up do
    alter table(:nats_operators) do
      add :encrypted_system_account_seed_ciphertext, :bytea
    end
  end

  def down do
    alter table(:nats_operators) do
      remove :encrypted_system_account_seed_ciphertext
    end
  end
end
