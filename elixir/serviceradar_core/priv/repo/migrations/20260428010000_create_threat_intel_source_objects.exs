defmodule ServiceRadar.Repo.Migrations.CreateThreatIntelSourceObjects do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:threat_intel_source_objects, primary_key: false, prefix: "platform") do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :provider, :text, null: false
      add :source, :text, null: false
      add :collection_id, :text
      add :object_id, :text, null: false
      add :object_type, :text, null: false
      add :object_version, :text, null: false, default: ""
      add :spec_version, :text
      add :date_added, :utc_datetime_usec
      add :modified_at, :utc_datetime_usec
      add :raw_object_key, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:threat_intel_source_objects, [:source], prefix: "platform")
    create index(:threat_intel_source_objects, [:provider], prefix: "platform")
    create index(:threat_intel_source_objects, [:collection_id], prefix: "platform")
    create index(:threat_intel_source_objects, [:object_type], prefix: "platform")
    create index(:threat_intel_source_objects, [:modified_at], prefix: "platform")

    create unique_index(
             :threat_intel_source_objects,
             [:source, :collection_id, :object_id, :object_version],
             prefix: "platform",
             name: "threat_intel_source_objects_identity_uidx"
           )
  end
end
