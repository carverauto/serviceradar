defmodule ServiceRadar.Repo.Migrations.AddAgentConfigAckTracking do
  @moduledoc """
  Adds per-agent config acknowledgement tracking for wedge detection (#4382):
  the last acked config version + per-section apply statuses, the last pushed
  config version (the ack expectation anchor), and the derived config health.
  """

  use Ecto.Migration

  def up do
    alter table(:ocsf_agents) do
      add :acked_config_version, :text
      add :config_acked_at, :utc_datetime
      add :config_section_statuses, {:array, :map}, default: []
      add :pushed_config_version, :text
      add :config_pushed_at, :utc_datetime
      add :config_health, :text, default: "unknown"
    end
  end

  def down do
    alter table(:ocsf_agents) do
      remove :config_health
      remove :config_pushed_at
      remove :pushed_config_version
      remove :config_section_statuses
      remove :config_acked_at
      remove :acked_config_version
    end
  end
end
