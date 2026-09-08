defmodule ServiceRadar.Repo.Migrations.AddProbeFieldsToCameraAnalysisWorkers do
  @moduledoc """
  Adds explicit probe configuration fields to registered camera analysis workers.
  """

  use Ecto.Migration

  def up do
    alter table(:camera_analysis_workers, prefix: "platform") do
      add :health_endpoint_url, :text
      add :health_path, :text
      add :health_timeout_ms, :integer
      add :probe_interval_ms, :integer
    end
  end

  def down do
    alter table(:camera_analysis_workers, prefix: "platform") do
      remove :probe_interval_ms
      remove :health_timeout_ms
      remove :health_path
      remove :health_endpoint_url
    end
  end
end
