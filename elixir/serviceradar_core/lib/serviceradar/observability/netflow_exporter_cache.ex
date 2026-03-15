defmodule ServiceRadar.Observability.NetflowExporterCache do
  @moduledoc """
  Cache for NetFlow exporter metadata keyed by `sampler_address`.

  This is a bounded lookup table to support SRQL dimensions like `exporter_name`.
  """

  use ServiceRadar.Observability.NetflowLookupCacheResource,
    table: "netflow_exporter_cache",
    key_fields: [
      {:sampler_address, :string, [primary_key?: true, allow_nil?: false]}
    ],
    fields: [
      {:exporter_name, :string, []},
      {:device_uid, :string, []},
      {:refreshed_at, :utc_datetime_usec, [allow_nil?: false]}
    ],
    identity: :unique_sampler_address,
    upsert_fields: [:exporter_name, :device_uid, :refreshed_at]
end
