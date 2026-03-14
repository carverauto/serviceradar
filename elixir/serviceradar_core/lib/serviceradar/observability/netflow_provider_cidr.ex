defmodule ServiceRadar.Observability.NetflowProviderCidr do
  @moduledoc """
  Cloud-provider CIDR entries for a specific dataset snapshot.
  """

  use ServiceRadar.Observability.NetflowDatasetEntryResource,
    table: "netflow_provider_cidrs",
    key_fields: [
      {:snapshot_id, :uuid, [primary_key?: true, allow_nil?: false]},
      {:cidr, ServiceRadar.Types.Cidr, [primary_key?: true, allow_nil?: false]},
      {:provider, :string, [primary_key?: true, allow_nil?: false]}
    ],
    fields: [
      {:service, :string, []},
      {:region, :string, []},
      {:ip_version, :string, []}
    ],
    identity: :unique_snapshot_cidr_provider,
    upsert_fields: [:service, :region, :ip_version]
end
