defmodule ServiceRadar.Repo.Migrations.AddNetflowAppClassificationRules do
  @moduledoc """
  Adds admin-managed NetFlow application classification override rules.

  These rules are evaluated at query time (SRQL) to derive an `app` label for flows.
  """

  use Ecto.Migration

  def up do
    create table(:netflow_app_classification_rules, primary_key: false, prefix: "platform") do
      add :id, :uuid, primary_key: true

      add :partition, :text
      add :enabled, :boolean, null: false, default: true

      add :priority, :bigint, null: false, default: 0

      add :protocol_num, :bigint
      add :dst_port, :bigint
      add :src_port, :bigint

      add :dst_cidr, :cidr
      add :src_cidr, :cidr

      add :app_label, :text, null: false
      add :notes, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:netflow_app_classification_rules, [:enabled], prefix: "platform")

    create index(:netflow_app_classification_rules, [:partition, :enabled], prefix: "platform")

    create index(:netflow_app_classification_rules, [:partition, :enabled, :protocol_num], prefix: "platform")

    create index(:netflow_app_classification_rules, [:partition, :enabled, :dst_port], prefix: "platform")

    create index(:netflow_app_classification_rules, [:partition, :enabled, :src_port], prefix: "platform")

    create index(
      :netflow_app_classification_rules,
      [:partition, :enabled, :protocol_num, :dst_port, :src_port, :priority],
      prefix: "platform"
    )

    execute("""
    CREATE INDEX IF NOT EXISTS idx_netflow_app_rules_dst_cidr_gist
      ON platform.netflow_app_classification_rules
      USING gist (dst_cidr)
      WHERE dst_cidr IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_netflow_app_rules_src_cidr_gist
      ON platform.netflow_app_classification_rules
      USING gist (src_cidr)
      WHERE src_cidr IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.idx_netflow_app_rules_src_cidr_gist")
    execute("DROP INDEX IF EXISTS platform.idx_netflow_app_rules_dst_cidr_gist")

    drop_if_exists index(:netflow_app_classification_rules, [:partition, :enabled, :protocol_num, :dst_port, :src_port, :priority],
                     prefix: "platform")

    drop_if_exists index(:netflow_app_classification_rules, [:partition, :enabled, :src_port], prefix: "platform")
    drop_if_exists index(:netflow_app_classification_rules, [:partition, :enabled, :dst_port], prefix: "platform")
    drop_if_exists index(:netflow_app_classification_rules, [:partition, :enabled, :protocol_num], prefix: "platform")
    drop_if_exists index(:netflow_app_classification_rules, [:partition, :enabled], prefix: "platform")
    drop_if_exists index(:netflow_app_classification_rules, [:enabled], prefix: "platform")

    drop table(:netflow_app_classification_rules, prefix: "platform")
  end
end

