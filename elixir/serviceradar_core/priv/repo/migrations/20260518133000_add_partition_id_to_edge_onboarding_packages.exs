defmodule ServiceRadar.Repo.Migrations.AddPartitionIdToEdgeOnboardingPackages do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:edge_onboarding_packages, prefix: @prefix) do
      add(:partition_id, :text, null: false, default: "default")
    end

    execute("""
    UPDATE platform.edge_onboarding_packages
    SET partition_id = COALESCE(NULLIF(BTRIM(site), ''), 'default'),
        site = COALESCE(NULLIF(BTRIM(site), ''), 'default')
    """)

    create(
      index(:edge_onboarding_packages, [:partition_id],
        name: :edge_onboarding_packages_partition_id_idx,
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(
      index(:edge_onboarding_packages, [:partition_id],
        name: :edge_onboarding_packages_partition_id_idx,
        prefix: @prefix
      )
    )

    alter table(:edge_onboarding_packages, prefix: @prefix) do
      remove(:partition_id)
    end
  end
end
