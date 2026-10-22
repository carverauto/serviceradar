defmodule ServiceRadar.Repo.Migrations.AddOtxRetrohuntIntervalToNetflowSettings do
  @moduledoc """
  Optional scheduled OTX retrohunt cadence. NULL keeps retrohunt manual-only,
  which is the default for existing and new installations.
  """
  use Ecto.Migration

  def change do
    alter table(:netflow_settings, prefix: "platform") do
      add :otx_retrohunt_interval_seconds, :integer
    end
  end
end
