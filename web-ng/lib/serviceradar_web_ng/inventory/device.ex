defmodule ServiceRadarWebNG.Inventory.Device do
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false, source: :device_id}
  @derive {Phoenix.Param, key: :id}
  schema "unified_devices" do
    field :ip, :string
    field :poller_id, :string
    field :agent_id, :string
    field :hostname, :string
    field :mac, :string
    field :discovery_sources, {:array, :string}
    field :is_available, :boolean
    field :first_seen, :utc_datetime
    field :last_seen, :utc_datetime
    field :metadata, :map
    field :device_type, :string
    field :service_type, :string
    field :service_status, :string
    field :last_heartbeat, :utc_datetime
    field :os_info, :string
    field :version_info, :string
    field :updated_at, :utc_datetime
  end
end
