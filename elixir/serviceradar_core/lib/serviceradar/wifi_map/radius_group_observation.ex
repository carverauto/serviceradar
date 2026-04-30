defmodule ServiceRadar.WifiMap.RadiusGroupObservation do
  @moduledoc "WiFi RADIUS/CPPM server-group mapping observed for a site/controller/profile."

  use Ash.Resource,
    domain: ServiceRadar.WifiMap,
    data_layer: AshPostgres.DataLayer

  @fields [
    :source_id,
    :batch_id,
    :controller_device_uid,
    :site_code,
    :collection_timestamp,
    :controller_alias,
    :aaa_profile,
    :server_group,
    :cluster,
    :all_server_groups,
    :status,
    :metadata
  ]

  postgres do
    table("wifi_radius_group_observations")
    repo(ServiceRadar.Repo)
    schema("platform")
    migrate?(false)

    identity_index_names(
      source_site_controller_profile_time: "wifi_radius_groups_src_site_ctrl_profile_time_idx"
    )
  end

  actions do
    defaults([:read, :destroy])

    create :upsert do
      accept(@fields)
      upsert?(true)
      upsert_identity(:source_site_controller_profile_time)
      upsert_fields(@fields ++ [:updated_at])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:source_id, :uuid, allow_nil?: false, public?: true)
    attribute(:batch_id, :uuid, public?: true)
    attribute(:controller_device_uid, :string, public?: true)
    attribute(:site_code, :string, allow_nil?: false, public?: true)
    attribute(:collection_timestamp, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:controller_alias, :string, public?: true)
    attribute(:aaa_profile, :string, public?: true)
    attribute(:server_group, :string, public?: true)
    attribute(:cluster, :string, public?: true)

    attribute(:all_server_groups, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true
    )

    attribute(:status, :string, public?: true)
    attribute(:metadata, :map, allow_nil?: false, default: %{}, public?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:source_site_controller_profile_time, [
      :source_id,
      :site_code,
      :controller_alias,
      :aaa_profile,
      :collection_timestamp
    ])
  end
end
