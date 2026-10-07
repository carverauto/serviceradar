defmodule ServiceRadar.Repo.Migrations.PreserveAlertSnapshotDiagnostics do
  use Ecto.Migration

  def change do
    alter table(:stateful_alert_rule_states, prefix: "platform") do
      add :first_seen_at, :utc_datetime_usec
      add :diagnostics, :map, default: %{}
    end
  end
end
