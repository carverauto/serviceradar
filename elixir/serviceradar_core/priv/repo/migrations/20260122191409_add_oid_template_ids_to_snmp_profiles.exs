defmodule ServiceRadar.Repo.Migrations.AddOidTemplateIdsToSnmpProfiles do
  @moduledoc """
  Adds oid_template_ids column to snmp_profiles table.

  This allows profiles to directly reference OID templates for SRQL-based
  device targeting, replacing the need for manual SNMPTarget configuration.
  """

  use Ecto.Migration

  def up do
    alter table(:snmp_profiles) do
      add :oid_template_ids, {:array, :uuid}, null: true, default: []
    end
  end

  def down do
    alter table(:snmp_profiles) do
      remove :oid_template_ids
    end
  end
end
