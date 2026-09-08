defmodule ServiceRadar.Repo.Migrations.AddFlappingFieldsToCameraAnalysisWorkers do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:camera_analysis_workers, prefix: "platform") do
      add :flapping, :boolean, null: false, default: false
      add :flapping_transition_count, :integer, null: false, default: 0
      add :flapping_window_size, :integer, null: false, default: 0
    end
  end
end
