defmodule ServiceRadar.Repo.Migrations.AddAlertFieldsToCameraAnalysisWorkers do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:camera_analysis_workers, prefix: "platform") do
      add :alert_active, :boolean, null: false, default: false
      add :alert_state, :text
      add :alert_reason, :text
    end
  end
end
