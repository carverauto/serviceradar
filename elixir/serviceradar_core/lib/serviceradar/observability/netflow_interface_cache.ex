defmodule ServiceRadar.Observability.NetflowInterfaceCache do
  @moduledoc """
  Cache for NetFlow interface metadata keyed by `(sampler_address, if_index)`.

  This is a bounded lookup table to support SRQL dimensions like `in_if_name`/`out_if_name`
  and future capacity-based units.
  """

  use ServiceRadar.Observability.NetflowLookupCacheResource,
    table: "netflow_interface_cache",
    key_fields: [
      {:sampler_address, :string, [primary_key?: true, allow_nil?: false]},
      {:if_index, :integer,
       [
         primary_key?: true,
         allow_nil?: false,
         description: "Interface index (SNMP ifIndex) from flow exporter"
       ]}
    ],
    fields: [
      {:device_uid, :string, []},
      {:if_name, :string, []},
      {:if_description, :string, []},
      {:if_speed_bps, :integer, []},
      {:boundary, :string, []},
      {:refreshed_at, :utc_datetime_usec, [allow_nil?: false]}
    ],
    identity: :unique_sampler_ifindex,
    upsert_fields: [:device_uid, :if_name, :if_description, :if_speed_bps, :boundary, :refreshed_at]
end
