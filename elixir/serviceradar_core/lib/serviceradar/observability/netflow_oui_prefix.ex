defmodule ServiceRadar.Observability.NetflowOuiPrefix do
  @moduledoc """
  IEEE OUI prefixes for a specific snapshot.
  """

  use ServiceRadar.Observability.NetflowDatasetEntryResource,
    table: "netflow_oui_prefixes",
    key_fields: [
      {:snapshot_id, :uuid, [primary_key?: true, allow_nil?: false]},
      {:oui_prefix_int, :integer, [primary_key?: true, allow_nil?: false]}
    ],
    fields: [
      {:oui_prefix_hex, :string, [allow_nil?: false]},
      {:organization, :string, [allow_nil?: false]}
    ],
    identity: :unique_snapshot_oui,
    upsert_fields: [:oui_prefix_hex, :organization]
end
