defmodule ServiceRadar.WifiMap.FleetHistory do
  @moduledoc "Fleet-level WiFi AP family migration history."

  use Ash.Resource,
    domain: ServiceRadar.WifiMap,
    data_layer: AshPostgres.DataLayer

  @fields [
    :source_id,
    :batch_id,
    :build_date,
    :ap_total,
    :count_2xx,
    :count_3xx,
    :count_4xx,
    :count_5xx,
    :count_6xx,
    :count_7xx,
    :count_other,
    :count_ap325,
    :pct_6xx,
    :pct_legacy,
    :site_count,
    :metadata
  ]

  postgres do
    table("wifi_fleet_history")
    repo(ServiceRadar.Repo)
    schema("platform")
    migrate?(false)
  end

  actions do
    defaults([:read, :destroy])

    create :upsert do
      accept(@fields)
      upsert?(true)
      upsert_identity(:source_build_date)
      upsert_fields(@fields ++ [:updated_at])
    end
  end

  attributes do
    attribute :source_id, :uuid do
      primary_key?(true)
      allow_nil?(false)
      public?(true)
    end

    attribute :build_date, :date do
      primary_key?(true)
      allow_nil?(false)
      public?(true)
    end

    attribute(:batch_id, :uuid, public?: true)
    attribute(:ap_total, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:count_2xx, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:count_3xx, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:count_4xx, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:count_5xx, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:count_6xx, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:count_7xx, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:count_other, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:count_ap325, :integer, public?: true)
    attribute(:pct_6xx, :float, public?: true)
    attribute(:pct_legacy, :float, public?: true)
    attribute(:site_count, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:metadata, :map, allow_nil?: false, default: %{}, public?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:source_build_date, [:source_id, :build_date])
  end
end
