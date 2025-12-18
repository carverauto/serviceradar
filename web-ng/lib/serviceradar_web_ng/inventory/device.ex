defmodule ServiceRadarWebNG.Inventory.Device do
  @moduledoc """
  Ecto schema for OCSF-aligned device inventory (OCSF v1.7.0 Device object).
  """
  use Ecto.Schema

  @primary_key {:uid, :string, autogenerate: false, source: :uid}
  @derive {Phoenix.Param, key: :uid}
  schema "ocsf_devices" do
    # OCSF Core Identity
    field :type_id, :integer
    field :type, :string
    field :name, :string
    field :hostname, :string
    field :ip, :string
    field :mac, :string

    # OCSF Extended Identity
    field :uid_alt, :string
    field :vendor_name, :string
    field :model, :string
    field :domain, :string
    field :zone, :string
    field :subnet_uid, :string
    field :vlan_uid, :string
    field :region, :string

    # OCSF Temporal
    field :first_seen_time, :utc_datetime
    field :last_seen_time, :utc_datetime
    field :created_time, :utc_datetime
    field :modified_time, :utc_datetime

    # OCSF Risk and Compliance
    field :risk_level_id, :integer
    field :risk_level, :string
    field :risk_score, :integer
    field :is_managed, :boolean
    field :is_compliant, :boolean
    field :is_trusted, :boolean

    # OCSF Nested Objects (JSONB)
    field :os, :map
    field :hw_info, :map
    field :network_interfaces, {:array, :map}
    field :owner, :map
    field :org, :map
    field :groups, {:array, :map}
    field :agent_list, {:array, :map}

    # ServiceRadar-specific fields
    field :poller_id, :string
    field :agent_id, :string
    field :discovery_sources, {:array, :string}
    field :is_available, :boolean
    field :metadata, :map
  end

  @doc """
  Returns the human-readable device type name from type_id.
  """
  def type_name(%__MODULE__{type: type}) when is_binary(type), do: type
  def type_name(%__MODULE__{type_id: 0}), do: "Unknown"
  def type_name(%__MODULE__{type_id: 1}), do: "Server"
  def type_name(%__MODULE__{type_id: 2}), do: "Desktop"
  def type_name(%__MODULE__{type_id: 3}), do: "Laptop"
  def type_name(%__MODULE__{type_id: 4}), do: "Tablet"
  def type_name(%__MODULE__{type_id: 5}), do: "Mobile"
  def type_name(%__MODULE__{type_id: 6}), do: "Virtual"
  def type_name(%__MODULE__{type_id: 7}), do: "IOT"
  def type_name(%__MODULE__{type_id: 8}), do: "Browser"
  def type_name(%__MODULE__{type_id: 9}), do: "Firewall"
  def type_name(%__MODULE__{type_id: 10}), do: "Switch"
  def type_name(%__MODULE__{type_id: 11}), do: "Hub"
  def type_name(%__MODULE__{type_id: 12}), do: "Router"
  def type_name(%__MODULE__{type_id: 13}), do: "IDS"
  def type_name(%__MODULE__{type_id: 14}), do: "IPS"
  def type_name(%__MODULE__{type_id: 15}), do: "Load Balancer"
  def type_name(%__MODULE__{type_id: 99}), do: "Other"
  def type_name(_), do: "Unknown"

  @doc """
  Returns the device_id (alias for uid for backward compatibility).
  """
  def device_id(%__MODULE__{uid: uid}), do: uid
end
