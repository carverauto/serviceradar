defmodule ServiceRadar.Repo.Migrations.RepairEdgeOnboardingNatsCredsCiphertextColumn do
  @moduledoc """
  Repairs early branch databases that ran the per-agent NATS creds migration
  before its AshCloak storage column name matched the resource.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = '#{@prefix}'
          AND table_name = 'edge_onboarding_packages'
          AND column_name = 'nats_creds_ciphertext'
      ) AND NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = '#{@prefix}'
          AND table_name = 'edge_onboarding_packages'
          AND column_name = 'encrypted_nats_creds_ciphertext'
      ) THEN
        ALTER TABLE #{@prefix}.edge_onboarding_packages
        RENAME COLUMN nats_creds_ciphertext TO encrypted_nats_creds_ciphertext;
      END IF;
    END $$;
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = '#{@prefix}'
          AND table_name = 'edge_onboarding_packages'
          AND column_name = 'encrypted_nats_creds_ciphertext'
      ) AND NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = '#{@prefix}'
          AND table_name = 'edge_onboarding_packages'
          AND column_name = 'nats_creds_ciphertext'
      ) THEN
        ALTER TABLE #{@prefix}.edge_onboarding_packages
        RENAME COLUMN encrypted_nats_creds_ciphertext TO nats_creds_ciphertext;
      END IF;
    END $$;
    """)
  end
end
