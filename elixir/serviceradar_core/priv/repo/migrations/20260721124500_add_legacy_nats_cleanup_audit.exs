defmodule ServiceRadar.Repo.Migrations.AddLegacyNatsCleanupAudit do
  @moduledoc """
  Records the explicit cleanup of legacy NATS material from onboarding packages.
  """

  use Ecto.Migration

  def up do
    alter table(:edge_onboarding_packages, prefix: "platform") do
      add(:legacy_nats_cleanup_at, :utc_datetime_usec)
      add(:legacy_nats_cleanup_reason, :text)
    end
  end

  def down do
    alter table(:edge_onboarding_packages, prefix: "platform") do
      remove(:legacy_nats_cleanup_reason)
      remove(:legacy_nats_cleanup_at)
    end
  end
end
