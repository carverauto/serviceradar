defmodule ServiceRadar.Repo.Migrations.CreateOtxRetrohuntTables do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:otx_retrohunt_runs, primary_key: false, prefix: "platform") do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :source, :text, null: false, default: "alienvault_otx"
      add :triggered_by, :text, null: false, default: "manual"
      add :status, :text, null: false, default: "running"
      add :window_start, :utc_datetime_usec, null: false
      add :window_end, :utc_datetime_usec, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :indicators_evaluated, :integer, null: false, default: 0
      add :findings_count, :integer, null: false, default: 0
      add :unsupported_count, :integer, null: false, default: 0
      add :error, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:otx_retrohunt_runs, [:source], prefix: "platform")
    create index(:otx_retrohunt_runs, [:status], prefix: "platform")
    create index(:otx_retrohunt_runs, [:started_at], prefix: "platform")

    create table(:otx_retrohunt_findings, primary_key: false, prefix: "platform") do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :run_id,
          references(:otx_retrohunt_runs,
            type: :uuid,
            prefix: "platform",
            on_delete: :nilify_all
          )

      add :indicator_id,
          references(:threat_intel_indicators,
            type: :uuid,
            prefix: "platform",
            on_delete: :nilify_all
          )

      add :source, :text, null: false, default: "alienvault_otx"
      add :indicator, :inet, null: false
      add :indicator_type, :text, null: false, default: "cidr"
      add :label, :text
      add :severity, :integer
      add :confidence, :integer
      add :observed_ip, :inet, null: false
      add :direction, :text, null: false
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      add :evidence_count, :integer, null: false, default: 0
      add :bytes_total, :bigint, null: false, default: 0
      add :packets_total, :bigint, null: false, default: 0
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:otx_retrohunt_findings, [:run_id], prefix: "platform")
    create index(:otx_retrohunt_findings, [:indicator_id], prefix: "platform")
    create index(:otx_retrohunt_findings, [:source], prefix: "platform")
    create index(:otx_retrohunt_findings, [:observed_ip], prefix: "platform")
    create index(:otx_retrohunt_findings, [:last_seen_at], prefix: "platform")
    create index(:otx_retrohunt_findings, [:severity], prefix: "platform")

    create unique_index(
             :otx_retrohunt_findings,
             [:source, :indicator, :observed_ip, :direction, :first_seen_at, :last_seen_at],
             prefix: "platform",
             name: "otx_retrohunt_findings_dedupe_uidx"
           )
  end
end
