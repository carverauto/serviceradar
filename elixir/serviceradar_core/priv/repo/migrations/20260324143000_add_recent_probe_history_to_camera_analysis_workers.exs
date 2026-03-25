defmodule ServiceRadar.Repo.Migrations.AddRecentProbeHistoryToCameraAnalysisWorkers do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:camera_analysis_workers, prefix: "platform") do
      add :recent_probe_results, {:array, :map}, null: false, default: []
    end
  end
end
