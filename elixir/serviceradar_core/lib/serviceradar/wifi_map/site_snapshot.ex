defmodule ServiceRadar.WifiMap.SiteSnapshot do
  @moduledoc "Per-site aggregate WiFi-map snapshot for AP, controller, and auth state."

  use Ash.Resource,
    domain: ServiceRadar.WifiMap,
    data_layer: AshPostgres.DataLayer

  @fields [
    :source_id,
    :batch_id,
    :site_code,
    :collection_timestamp,
    :ap_count,
    :up_count,
    :down_count,
    :model_breakdown,
    :controller_names,
    :wlc_count,
    :wlc_model_breakdown,
    :aos_version_breakdown,
    :server_group,
    :cluster,
    :all_server_groups,
    :aaa_profile,
    :metadata
  ]

  postgres do
    table("wifi_site_snapshots")
    repo(ServiceRadar.Repo)
    schema("platform")
    migrate?(false)
  end

  actions do
    defaults([:read, :destroy])

    create :upsert do
      accept(@fields)
      upsert?(true)
      upsert_identity(:source_site_time)
      upsert_fields(@fields ++ [:updated_at])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:source_id, :uuid, allow_nil?: false, public?: true)
    attribute(:batch_id, :uuid, public?: true)
    attribute(:site_code, :string, allow_nil?: false, public?: true)
    attribute(:collection_timestamp, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:ap_count, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:up_count, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:down_count, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:model_breakdown, :map, allow_nil?: false, default: %{}, public?: true)
    attribute(:controller_names, {:array, :string}, allow_nil?: false, default: [], public?: true)
    attribute(:wlc_count, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:wlc_model_breakdown, :map, allow_nil?: false, default: %{}, public?: true)
    attribute(:aos_version_breakdown, :map, allow_nil?: false, default: %{}, public?: true)
    attribute(:server_group, :string, public?: true)
    attribute(:cluster, :string, public?: true)

    attribute(:all_server_groups, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true
    )

    attribute(:aaa_profile, :string, public?: true)
    attribute(:metadata, :map, allow_nil?: false, default: %{}, public?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:source_site_time, [:source_id, :site_code, :collection_timestamp])
  end
end
