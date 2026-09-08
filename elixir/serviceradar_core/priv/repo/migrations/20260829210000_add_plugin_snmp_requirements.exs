defmodule ServiceRadar.Repo.Migrations.AddPluginSnmpRequirements do
  @moduledoc """
  Lets a plugin package declare the SNMP data it needs, and gives the collected
  values a home attached to the device they came from.

  Four changes:

    * `plugin_packages.snmp_requirements` — the manifest's declarations, stored
      on the package exactly as `alert_rules` and `producer_schedules` are.

    * `snmp_oid_templates.plugin_package_id` and
      `snmp_profiles.plugin_package_id` — provenance, nullable, so an operator
      can tell plugin-contributed configuration from their own. Nullable because
      every template and profile that exists today was authored by an operator,
      and those keep a NULL here.

    * `device_snmp_facts` — the current value of each declared OID per device.

  `device_snmp_facts` exists because `timeseries_metrics.value` is a
  non-nullable float while `string` is a legal SNMP data type. A software
  version, a node role, a service name — the values that are facts about a
  device rather than a series to graph — can be collected successfully today
  and then have nowhere to land. Numeric OIDs keep going to
  `timeseries_metrics`; this is the current-state surface beside it.

  The two FK behaviours differ on purpose:

    * `device_uid` CASCADEs. A fact is a statement about a device; when the
      device is gone the statement is meaningless, and an orphan keyed to a uid
      nothing resolves is worse than no row.

    * `plugin_package_id` NILIFIEs, matching `add_plugin_alert_rules`. Removing
      a package must not delete configuration an operator tuned, nor facts
      already collected. Provenance is lost; the data is not.
  """

  use Ecto.Migration

  def up do
    alter table(:plugin_packages, prefix: "platform") do
      add_if_not_exists :snmp_requirements, {:array, :map}
    end

    for table <- [:snmp_oid_templates, :snmp_profiles] do
      alter table(table, prefix: "platform") do
        add_if_not_exists :plugin_package_id,
                          references(:plugin_packages,
                            prefix: "platform",
                            type: :uuid,
                            on_delete: :nilify_all
                          )
      end

      create_if_not_exists index(table, [:plugin_package_id], prefix: "platform")
    end

    create_if_not_exists table(:device_snmp_facts, prefix: "platform", primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :device_uid,
          references(:ocsf_devices,
            prefix: "platform",
            column: :uid,
            name: "device_snmp_facts_device_uid_fkey",
            type: :text,
            on_delete: :delete_all
          ),
          null: false

      add :oid, :text, null: false
      add :oid_name, :text, null: false

      # An empty string, not NULL, for a scalar get. NULL in a unique index does
      # not compare equal to NULL, so a nullable column here would let the same
      # scalar OID be inserted repeatedly instead of being upserted.
      add :oid_index, :text, null: false, default: ""

      add :value, :text
      add :data_type, :text, null: false

      add :plugin_package_id,
          references(:plugin_packages,
            prefix: "platform",
            type: :uuid,
            on_delete: :nilify_all
          )

      add :snmp_profile_id, :uuid
      add :collected_at, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create_if_not_exists unique_index(
                           :device_snmp_facts,
                           [:device_uid, :oid, :oid_index],
                           prefix: "platform",
                           name: "device_snmp_facts_unique_reading_idx"
                         )

    create_if_not_exists index(:device_snmp_facts, [:plugin_package_id], prefix: "platform")
    create_if_not_exists index(:device_snmp_facts, [:collected_at], prefix: "platform")
  end

  def down do
    drop_if_exists table(:device_snmp_facts, prefix: "platform")

    for table <- [:snmp_oid_templates, :snmp_profiles] do
      drop_if_exists index(table, [:plugin_package_id], prefix: "platform")

      alter table(table, prefix: "platform") do
        remove_if_exists :plugin_package_id
      end
    end

    alter table(:plugin_packages, prefix: "platform") do
      remove_if_exists :snmp_requirements
    end
  end
end
