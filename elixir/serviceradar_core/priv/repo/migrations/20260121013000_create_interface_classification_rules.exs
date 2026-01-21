defmodule ServiceRadar.Repo.Migrations.CreateInterfaceClassificationRules do
  @moduledoc """
  Adds interface classification rule definitions.
  """

  use Ecto.Migration

  def up do
    create table(:interface_classification_rules, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :enabled, :boolean, null: false, default: true
      add :priority, :integer, null: false, default: 0
      add :vendor_pattern, :text
      add :model_pattern, :text
      add :sys_descr_pattern, :text
      add :if_name_pattern, :text
      add :if_descr_pattern, :text
      add :if_alias_pattern, :text
      add :if_type_ids, {:array, :integer}, null: false, default: []
      add :ip_cidr_allow, {:array, :text}, null: false, default: []
      add :ip_cidr_deny, {:array, :text}, null: false, default: []
      add :classifications, {:array, :text}, null: false, default: []
      add :metadata, :map, null: false, default: %{}

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:interface_classification_rules, [:name],
             name: "interface_classification_rules_unique_name_index"
           )

    create index(:interface_classification_rules, [:enabled],
             name: "interface_classification_rules_enabled_idx"
           )

    create index(:interface_classification_rules, [:priority],
             name: "interface_classification_rules_priority_idx"
           )

    execute("""
    INSERT INTO interface_classification_rules
      (name, enabled, priority, vendor_pattern, if_name_pattern, if_descr_pattern, classifications, inserted_at, updated_at)
    VALUES
      (
        'ubiquiti_management_adapter',
        true,
        100,
        '(?i)ubiquiti|unifi',
        NULL,
        '(?i)Annapurna Labs Ltd\\..*Ethernet Adapter',
        ARRAY['management']::text[],
        (now() AT TIME ZONE 'utc'),
        (now() AT TIME ZONE 'utc')
      ),
      (
        'wireguard_interface_name',
        true,
        90,
        NULL,
        '(?i)^wg',
        NULL,
        ARRAY['vpn','wireguard']::text[],
        (now() AT TIME ZONE 'utc'),
        (now() AT TIME ZONE 'utc')
      ),
      (
        'wireguard_interface_descr',
        true,
        80,
        NULL,
        NULL,
        '(?i)wireguard',
        ARRAY['vpn','wireguard']::text[],
        (now() AT TIME ZONE 'utc'),
        (now() AT TIME ZONE 'utc')
      )
    """)
  end

  def down do
    execute("""
    DELETE FROM interface_classification_rules
    WHERE name IN (
      'ubiquiti_management_adapter',
      'wireguard_interface_name',
      'wireguard_interface_descr'
    )
    """)

    drop_if_exists index(:interface_classification_rules,
                     [:priority],
                     name: "interface_classification_rules_priority_idx"
                   )

    drop_if_exists index(:interface_classification_rules,
                     [:enabled],
                     name: "interface_classification_rules_enabled_idx"
                   )

    drop_if_exists unique_index(:interface_classification_rules,
                     [:name],
                     name: "interface_classification_rules_unique_name_index"
                   )

    drop_if_exists table(:interface_classification_rules)
  end
end
