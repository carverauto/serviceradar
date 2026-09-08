defmodule ServiceRadar.Repo.Migrations.AddSrqlQueryToDeviceHostnameRdnsSettings do
  @moduledoc """
  SRQL cohort selector for scheduled reverse-DNS hostname enrichment.
  """

  use Ecto.Migration

  def up do
    alter table(:device_hostname_rdns_settings, prefix: "platform") do
      add :srql_query, :text,
        null: false,
        default: "in:devices sort:last_seen:desc"

      add :last_cohort_rows, :integer, null: false, default: 0
      add :last_candidates, :integer, null: false, default: 0
    end
  end

  def down do
    alter table(:device_hostname_rdns_settings, prefix: "platform") do
      remove :srql_query
      remove :last_cohort_rows
      remove :last_candidates
    end
  end
end
