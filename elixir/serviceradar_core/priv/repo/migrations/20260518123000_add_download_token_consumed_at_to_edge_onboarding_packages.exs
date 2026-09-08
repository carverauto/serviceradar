defmodule ServiceRadar.Repo.Migrations.AddDownloadTokenConsumedAtToEdgeOnboardingPackages do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:edge_onboarding_packages, prefix: @prefix) do
      add(:download_token_consumed_at, :utc_datetime)
    end
  end

  def down do
    alter table(:edge_onboarding_packages, prefix: @prefix) do
      remove(:download_token_consumed_at)
    end
  end
end
