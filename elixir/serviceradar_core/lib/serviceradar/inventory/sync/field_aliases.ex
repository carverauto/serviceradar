defmodule ServiceRadar.Inventory.Sync.FieldAliases do
  @moduledoc "Shared payload/metadata key alias lists for sync normalization and enrichment."

  @device_type_aliases [
    "type",
    :type,
    "device_type",
    :device_type,
    "deviceType",
    :deviceType,
    "type_name",
    :type_name,
    "deviceTypeName",
    :deviceTypeName,
    "armis_type",
    :armis_type,
    "netbox_device_type",
    :netbox_device_type,
    "netbox_role",
    :netbox_role,
    "ansible_device_type",
    :ansible_device_type,
    "proxmox_type",
    :proxmox_type,
    "proxmox_node_type",
    :proxmox_node_type,
    "vm_type",
    :vm_type,
    "device_role",
    :device_role,
    "deviceRole",
    :deviceRole,
    "role",
    :role,
    "category",
    :category,
    "armis_category",
    :armis_category
  ]
  @vendor_aliases [
    "vendor_name",
    :vendor_name,
    "vendor",
    :vendor,
    "manufacturer",
    :manufacturer,
    "brand",
    :brand,
    "make",
    :make,
    "vendorName",
    :vendorName
  ]
  @model_aliases [
    "model",
    :model,
    "device_model",
    :device_model,
    "model_name",
    :model_name,
    "modelName",
    :modelName,
    "product",
    :product,
    "product_name",
    :product_name
  ]
  @vendor_tokens [
    {"cisco", "Cisco"},
    {"juniper", "Juniper"},
    {"arista", "Arista"},
    {"ubiquiti", "Ubiquiti"},
    {"unifi", "Ubiquiti"},
    {"ubnt", "Ubiquiti"},
    {"mikrotik", "MikroTik"},
    {"fortinet", "Fortinet"},
    {"palo alto", "Palo Alto Networks"},
    {"checkpoint", "Check Point"},
    {"hpe", "HPE"},
    {"hewlett-packard", "HPE"},
    {"hp", "HP"},
    {"dell", "Dell"},
    {"netgear", "Netgear"}
  ]

  def device_type_aliases, do: @device_type_aliases
  def vendor_aliases, do: @vendor_aliases
  def model_aliases, do: @model_aliases
  def vendor_tokens, do: @vendor_tokens
end
