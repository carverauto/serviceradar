defmodule ServiceRadar.Repo.Migrations.AddNatsCredsToEdgeOnboardingPackages do
  @moduledoc """
  Adds per-agent flow-collector NATS credential columns to
  `platform.edge_onboarding_packages`. The credentials are minted by
  `ServiceRadar.Edge.Workers.ProvisionAgentWorker` and tarred into the
  agent bundle on download (B-5 sub-issue 1).
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:edge_onboarding_packages, prefix: @prefix) do
      add(:nats_credential_id, :uuid, null: true)
      # AshCloak stores attribute `:nats_creds_ciphertext` in the
      # `encrypted_nats_creds_ciphertext` physical column.
      add(:encrypted_nats_creds_ciphertext, :binary, null: true)
    end

    create(
      index(:edge_onboarding_packages, [:nats_credential_id],
        name: :edge_onboarding_packages_nats_credential_id_idx,
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(
      index(:edge_onboarding_packages, [:nats_credential_id],
        name: :edge_onboarding_packages_nats_credential_id_idx,
        prefix: @prefix
      )
    )

    alter table(:edge_onboarding_packages, prefix: @prefix) do
      remove(:nats_credential_id)
      remove(:encrypted_nats_creds_ciphertext)
    end
  end
end
