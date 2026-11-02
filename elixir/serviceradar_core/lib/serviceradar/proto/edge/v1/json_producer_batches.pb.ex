defmodule Serviceradar.Edge.V1.MapperDeviceBatchV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperDeviceBatchV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :agent_id, 1, type: :string, json_name: "agentId"
  field :gateway_id, 2, type: :string, json_name: "gatewayId"
  field :partition, 3, type: :string
  field :devices, 4, repeated: true, type: Serviceradar.Edge.V1.MapperDeviceRecordV1
end

defmodule Serviceradar.Edge.V1.MapperDeviceRecordV1.MetadataEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperDeviceRecordV1.MetadataEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Edge.V1.MapperDeviceRecordV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperDeviceRecordV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :device_id, 1, type: :string, json_name: "deviceId"
  field :ip, 2, type: :string
  field :source, 3, type: :string
  field :timestamp_unix_nano, 4, type: :int64, json_name: "timestampUnixNano"
  field :is_available, 5, type: :bool, json_name: "isAvailable"
  field :hostname, 6, type: :string
  field :mac, 7, type: :string
  field :agent_id, 8, type: :string, json_name: "agentId"
  field :gateway_id, 9, type: :string, json_name: "gatewayId"
  field :partition, 10, type: :string

  field :snmp_fingerprint, 11,
    type: Serviceradar.Edge.V1.MapperSnmpFingerprintV1,
    json_name: "snmpFingerprint"

  field :sync_service_id, 12, type: :string, json_name: "syncServiceId"
  field :identity_mac_kind, 13, type: :string, json_name: "identityMacKind"
  field :sys_descr, 14, type: :string, json_name: "sysDescr"
  field :snmp_description, 15, type: :string, json_name: "snmpDescription"
  field :sys_object_id, 16, type: :string, json_name: "sysObjectId"
  field :sys_name, 17, type: :string, json_name: "sysName"
  field :snmp_name, 18, type: :string, json_name: "snmpName"
  field :sys_contact, 19, type: :string, json_name: "sysContact"
  field :sys_owner, 20, type: :string, json_name: "sysOwner"
  field :snmp_owner, 21, type: :string, json_name: "snmpOwner"
  field :sys_location, 22, type: :string, json_name: "sysLocation"
  field :snmp_location, 23, type: :string, json_name: "snmpLocation"
  field :ip_forwarding, 24, type: :int32, json_name: "ipForwarding"
  field :bridge_base_mac, 25, type: :string, json_name: "bridgeBaseMac"
  field :uptime, 26, type: :int64
  field :first_seen_unix_nano, 27, type: :int64, json_name: "firstSeenUnixNano"
  field :last_seen_unix_nano, 28, type: :int64, json_name: "lastSeenUnixNano"

  field :metadata, 29,
    repeated: true,
    type: Serviceradar.Edge.V1.MapperDeviceRecordV1.MetadataEntry,
    map: true
end

defmodule Serviceradar.Edge.V1.MapperSnmpFingerprintV1.ExtractionErrorsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperSnmpFingerprintV1.ExtractionErrorsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Edge.V1.MapperSnmpFingerprintV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperSnmpFingerprintV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :system, 1, type: Serviceradar.Edge.V1.MapperSnmpSystemFingerprintV1
  field :bridge, 2, type: Serviceradar.Edge.V1.MapperSnmpBridgeFingerprintV1
  field :vlan, 3, type: Serviceradar.Edge.V1.MapperSnmpVlanFingerprintV1

  field :interface_summary, 4,
    type: Serviceradar.Edge.V1.MapperSnmpInterfaceSummaryV1,
    json_name: "interfaceSummary"

  field :extraction_errors, 5,
    repeated: true,
    type: Serviceradar.Edge.V1.MapperSnmpFingerprintV1.ExtractionErrorsEntry,
    json_name: "extractionErrors",
    map: true
end

defmodule Serviceradar.Edge.V1.MapperSnmpSystemFingerprintV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperSnmpSystemFingerprintV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :sys_name, 1, type: :string, json_name: "sysName"
  field :sys_descr, 2, type: :string, json_name: "sysDescr"
  field :sys_object_id, 3, type: :string, json_name: "sysObjectId"
  field :sys_contact, 4, type: :string, json_name: "sysContact"
  field :sys_location, 5, type: :string, json_name: "sysLocation"
  field :ip_forwarding, 6, type: :int32, json_name: "ipForwarding"
end

defmodule Serviceradar.Edge.V1.MapperSnmpBridgeFingerprintV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperSnmpBridgeFingerprintV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :bridge_base_mac, 1, type: :string, json_name: "bridgeBaseMac"
  field :bridge_port_count, 2, type: :int32, json_name: "bridgePortCount"
  field :stp_forwarding_port_count, 3, type: :int32, json_name: "stpForwardingPortCount"
end

defmodule Serviceradar.Edge.V1.MapperSnmpVlanFingerprintV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperSnmpVlanFingerprintV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :vlan_ids_seen, 1, repeated: true, type: :int32, json_name: "vlanIdsSeen"

  field :pvid_distribution, 2,
    repeated: true,
    type: Serviceradar.Edge.V1.MapperSnmpVlanPvidCountV1,
    json_name: "pvidDistribution"

  field :port_evidence, 3,
    repeated: true,
    type: Serviceradar.Edge.V1.MapperSnmpVlanPortEvidenceV1,
    json_name: "portEvidence"
end

defmodule Serviceradar.Edge.V1.MapperSnmpVlanPvidCountV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperSnmpVlanPvidCountV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :pvid, 1, type: :int32
  field :count, 2, type: :int32
end

defmodule Serviceradar.Edge.V1.MapperSnmpVlanPortEvidenceV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperSnmpVlanPortEvidenceV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :vlan_id, 1, type: :int32, json_name: "vlanId"
  field :egress_ports_hex, 2, type: :string, json_name: "egressPortsHex"
  field :untagged_ports_hex, 3, type: :string, json_name: "untaggedPortsHex"
end

defmodule Serviceradar.Edge.V1.MapperSnmpInterfaceSummaryV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperSnmpInterfaceSummaryV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :interface_count, 1, type: :int32, json_name: "interfaceCount"

  field :if_type_counts, 2,
    repeated: true,
    type: Serviceradar.Edge.V1.MapperSnmpIfTypeCountV1,
    json_name: "ifTypeCounts"

  field :bridge_like_name_count, 3, type: :int32, json_name: "bridgeLikeNameCount"
  field :wireless_like_name_count, 4, type: :int32, json_name: "wirelessLikeNameCount"
end

defmodule Serviceradar.Edge.V1.MapperSnmpIfTypeCountV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperSnmpIfTypeCountV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :if_type, 1, type: :int32, json_name: "ifType"
  field :count, 2, type: :int32
end

defmodule Serviceradar.Edge.V1.MapperInterfaceBatchV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperInterfaceBatchV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :agent_id, 1, type: :string, json_name: "agentId"
  field :gateway_id, 2, type: :string, json_name: "gatewayId"
  field :partition, 3, type: :string
  field :interfaces, 4, repeated: true, type: Serviceradar.Edge.V1.MapperInterfaceRecordV1
end

defmodule Serviceradar.Edge.V1.MapperInterfaceRecordV1.MetadataEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperInterfaceRecordV1.MetadataEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Edge.V1.MapperInterfaceRecordV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperInterfaceRecordV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :device_id, 1, type: :string, json_name: "deviceId"
  field :device_ip, 2, type: :string, json_name: "deviceIp"
  field :if_index, 3, type: :int32, json_name: "ifIndex"
  field :if_name, 4, type: :string, json_name: "ifName"
  field :if_descr, 5, type: :string, json_name: "ifDescr"
  field :if_alias, 6, type: :string, json_name: "ifAlias"
  field :if_speed, 7, type: :uint64, json_name: "ifSpeed"
  field :speed_bps, 8, proto3_optional: true, type: :uint64, json_name: "speedBps"
  field :if_phys_address, 9, type: :string, json_name: "ifPhysAddress"
  field :ip_addresses, 10, repeated: true, type: :string, json_name: "ipAddresses"
  field :if_admin_status, 11, type: :int32, json_name: "ifAdminStatus"
  field :if_oper_status, 12, type: :int32, json_name: "ifOperStatus"
  field :if_type, 13, type: :int32, json_name: "ifType"
  field :mtu, 14, proto3_optional: true, type: :int32
  field :duplex, 15, type: :string
  field :source, 16, type: :string

  field :metadata, 17,
    repeated: true,
    type: Serviceradar.Edge.V1.MapperInterfaceRecordV1.MetadataEntry,
    map: true

  field :available_metrics, 18,
    repeated: true,
    type: Serviceradar.Edge.V1.MapperInterfaceMetricV1,
    json_name: "availableMetrics"

  field :timestamp_unix_nano, 19, type: :int64, json_name: "timestampUnixNano"
  field :agent_id, 20, type: :string, json_name: "agentId"
  field :gateway_id, 21, type: :string, json_name: "gatewayId"
  field :partition, 22, type: :string
end

defmodule Serviceradar.Edge.V1.MapperInterfaceMetricV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperInterfaceMetricV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :oid, 2, type: :string
  field :data_type, 3, type: :string, json_name: "dataType"
  field :supports_64bit, 4, type: :bool, json_name: "supports64bit"
  field :oid_64bit, 5, type: :string, json_name: "oid64bit"
  field :category, 6, type: :string
  field :unit, 7, type: :string
end

defmodule Serviceradar.Edge.V1.MapperTopologyBatchV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperTopologyBatchV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :agent_id, 1, type: :string, json_name: "agentId"
  field :gateway_id, 2, type: :string, json_name: "gatewayId"
  field :partition, 3, type: :string
  field :links, 4, repeated: true, type: Serviceradar.Edge.V1.MapperTopologyLinkRecordV1
end

defmodule Serviceradar.Edge.V1.MapperTopologyLinkRecordV1.MetadataEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperTopologyLinkRecordV1.MetadataEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Edge.V1.MapperTopologyLinkRecordV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperTopologyLinkRecordV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :protocol, 1, type: :string
  field :local_device_ip, 2, type: :string, json_name: "localDeviceIp"
  field :local_device_id, 3, type: :string, json_name: "localDeviceId"
  field :local_if_index, 4, type: :int32, json_name: "localIfIndex"
  field :local_if_name, 5, type: :string, json_name: "localIfName"
  field :neighbor_device_id, 6, type: :string, json_name: "neighborDeviceId"
  field :neighbor_chassis_id, 7, type: :string, json_name: "neighborChassisId"
  field :neighbor_port_id, 8, type: :string, json_name: "neighborPortId"
  field :neighbor_port_descr, 9, type: :string, json_name: "neighborPortDescr"
  field :neighbor_system_name, 10, type: :string, json_name: "neighborSystemName"
  field :neighbor_mgmt_addr, 11, type: :string, json_name: "neighborMgmtAddr"

  field :neighbor_identity, 12,
    type: Serviceradar.Edge.V1.MapperNeighborIdentityV1,
    json_name: "neighborIdentity"

  field :observation, 13, type: Serviceradar.Edge.V1.MapperTopologyObservationV2
  field :confidence_tier, 14, type: :string, json_name: "confidenceTier"
  field :confidence_score, 15, type: :int32, json_name: "confidenceScore"
  field :confidence_reason, 16, type: :string, json_name: "confidenceReason"

  field :metadata, 17,
    repeated: true,
    type: Serviceradar.Edge.V1.MapperTopologyLinkRecordV1.MetadataEntry,
    map: true

  field :timestamp_unix_nano, 18, type: :int64, json_name: "timestampUnixNano"
  field :agent_id, 19, type: :string, json_name: "agentId"
  field :gateway_id, 20, type: :string, json_name: "gatewayId"
  field :partition, 21, type: :string
end

defmodule Serviceradar.Edge.V1.MapperNeighborIdentityV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperNeighborIdentityV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :management_ip, 1, type: :string, json_name: "managementIp"
  field :device_id, 2, type: :string, json_name: "deviceId"
  field :chassis_id, 3, type: :string, json_name: "chassisId"
  field :port_id, 4, type: :string, json_name: "portId"
  field :port_descr, 5, type: :string, json_name: "portDescr"
  field :system_name, 6, type: :string, json_name: "systemName"
end

defmodule Serviceradar.Edge.V1.MapperTopologyObservationV2.RawAttributesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperTopologyObservationV2.RawAttributesEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Edge.V1.MapperTopologyObservationV2 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperTopologyObservationV2",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  alias Serviceradar.Edge.V1.MapperTopologyEndpointV1

  field :contract_version, 1, type: :string, json_name: "contractVersion"
  field :observation_type, 2, type: :string, json_name: "observationType"
  field :source_protocol, 3, type: :string, json_name: "sourceProtocol"
  field :source_adapter, 4, type: :string, json_name: "sourceAdapter"
  field :evidence_class, 5, type: :string, json_name: "evidenceClass"
  field :confidence_tier, 6, type: :string, json_name: "confidenceTier"
  field :confidence_score, 7, type: :int32, json_name: "confidenceScore"
  field :confidence_reason, 8, type: :string, json_name: "confidenceReason"
  field :observed_at_unix, 9, type: :int64, json_name: "observedAtUnix"
  field :discovery_id, 10, type: :string, json_name: "discoveryId"

  field :source_endpoint, 11,
    type: MapperTopologyEndpointV1,
    json_name: "sourceEndpoint"

  field :target_endpoint, 12,
    type: MapperTopologyEndpointV1,
    json_name: "targetEndpoint"

  field :raw_attributes, 13,
    repeated: true,
    type: Serviceradar.Edge.V1.MapperTopologyObservationV2.RawAttributesEntry,
    json_name: "rawAttributes",
    map: true

  field :relation_family, 14, type: :string, json_name: "relationFamily"
end

defmodule Serviceradar.Edge.V1.MapperTopologyEndpointV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperTopologyEndpointV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :uid, 1, type: :string
  field :device_id, 2, type: :string, json_name: "deviceId"
  field :ip, 3, type: :string
  field :mac, 4, type: :string
  field :port_id, 5, type: :string, json_name: "portId"
  field :if_name, 6, type: :string, json_name: "ifName"
  field :if_index, 7, type: :int32, json_name: "ifIndex"
  field :sys_name, 8, type: :string, json_name: "sysName"
end

defmodule Serviceradar.Edge.V1.MapperResultsBatchV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MapperResultsBatchV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :agent_id, 1, type: :string, json_name: "agentId"
  field :gateway_id, 2, type: :string, json_name: "gatewayId"
  field :partition, 3, type: :string
  field :devices, 4, repeated: true, type: Serviceradar.Edge.V1.MapperDeviceRecordV1
  field :interfaces, 5, repeated: true, type: Serviceradar.Edge.V1.MapperInterfaceRecordV1

  field :topology_links, 6,
    repeated: true,
    type: Serviceradar.Edge.V1.MapperTopologyLinkRecordV1,
    json_name: "topologyLinks"
end

defmodule Serviceradar.Edge.V1.NetprobeDiscoveryBatchV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.NetprobeDiscoveryBatchV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :records, 1, repeated: true, type: Serviceradar.Edge.V1.NetprobeDiscoveryRecordV1
end

defmodule Serviceradar.Edge.V1.NetprobeDiscoveryRecordV1.MetadataEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.NetprobeDiscoveryRecordV1.MetadataEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Edge.V1.NetprobeDiscoveryRecordV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.NetprobeDiscoveryRecordV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof(:observation, 0)

  field :ip, 1, type: :string
  field :agent_id, 2, type: :string, json_name: "agentId"
  field :gateway_id, 3, type: :string, json_name: "gatewayId"
  field :partition, 4, type: :string
  field :source, 5, type: :string
  field :discovery_source, 6, type: :string, json_name: "discoverySource"
  field :collector_ip, 7, type: :string, json_name: "collectorIp"
  field :alias_last_seen_ip, 8, type: :string, json_name: "aliasLastSeenIp"
  field :alias_last_seen_at_unix_nano, 9, type: :int64, json_name: "aliasLastSeenAtUnixNano"
  field :timestamp_unix_nano, 10, type: :int64, json_name: "timestampUnixNano"

  field :metadata, 11,
    repeated: true,
    type: Serviceradar.Edge.V1.NetprobeDiscoveryRecordV1.MetadataEntry,
    map: true

  field :fingerprint, 12, type: Serviceradar.Edge.V1.NetprobeFingerprintObservationV1, oneof: 0
  field :dpi, 13, type: Serviceradar.Edge.V1.NetprobeDpiObservationV1, oneof: 0

  field :process_snapshot, 14,
    type: Serviceradar.Edge.V1.NetprobeProcessSnapshotObservationV1,
    json_name: "processSnapshot",
    oneof: 0
end

defmodule Serviceradar.Edge.V1.NetprobeFingerprintObservationV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.NetprobeFingerprintObservationV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :source, 1, type: :string
  field :profile_id, 2, type: :string, json_name: "profileId"
  field :profile_name, 3, type: :string, json_name: "profileName"
  field :interface_name, 4, type: :string, json_name: "interfaceName"
  field :observed_at_unix_nano, 5, type: :int64, json_name: "observedAtUnixNano"
  field :protocol, 6, type: :string
  field :tcp, 7, type: Serviceradar.Edge.V1.NetprobeTcpFingerprintV1
  field :tls, 8, type: Serviceradar.Edge.V1.NetprobeTlsFingerprintV1
  field :http, 9, type: Serviceradar.Edge.V1.NetprobeHttpFingerprintV1

  field :license_clean, 10,
    type: Serviceradar.Edge.V1.NetprobeLicenseCleanFingerprintV1,
    json_name: "licenseClean"
end

defmodule Serviceradar.Edge.V1.NetprobeTcpFingerprintV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.NetprobeTcpFingerprintV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :signature, 1, type: :string
  field :os_family, 2, type: :string, json_name: "osFamily"
  field :os_name, 3, type: :string, json_name: "osName"
  field :confidence, 4, type: :float
  field :ttl, 5, type: :uint32
  field :window_size, 6, type: :string, json_name: "windowSize"
  field :mss, 7, type: :uint32
  field :options_layout, 8, repeated: true, type: :string, json_name: "optionsLayout"
  field :quirks, 9, repeated: true, type: :string
  field :ip_version, 10, type: :string, json_name: "ipVersion"
  field :window_scale, 11, type: :uint32, json_name: "windowScale"
  field :payload_class, 12, type: :string, json_name: "payloadClass"
end

defmodule Serviceradar.Edge.V1.NetprobeTlsFingerprintV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.NetprobeTlsFingerprintV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :ja4, 1, type: :string
  field :ja4s, 2, type: :string
  field :sni_redacted, 3, type: :string, json_name: "sniRedacted"
end

defmodule Serviceradar.Edge.V1.NetprobeHttpFingerprintV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.NetprobeHttpFingerprintV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :user_agent, 1, type: :string, json_name: "userAgent"
  field :server, 2, type: :string
  field :accept_language, 3, type: :string, json_name: "acceptLanguage"
end

defmodule Serviceradar.Edge.V1.NetprobeLicenseCleanFingerprintV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.NetprobeLicenseCleanFingerprintV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  alias Serviceradar.Edge.V1.NetprobeRecogMatchV1

  field :os_match, 1, type: Serviceradar.Edge.V1.NetprobeOsMatchV1, json_name: "osMatch"
  field :recog_http, 2, type: NetprobeRecogMatchV1, json_name: "recogHttp"
  field :recog_ssh, 3, type: NetprobeRecogMatchV1, json_name: "recogSsh"
  field :recog_smb, 4, type: NetprobeRecogMatchV1, json_name: "recogSmb"
  field :recog_ftp, 5, type: NetprobeRecogMatchV1, json_name: "recogFtp"

  field :recog_telnet, 6,
    type: NetprobeRecogMatchV1,
    json_name: "recogTelnet"

  field :recog_smtp, 7, type: NetprobeRecogMatchV1, json_name: "recogSmtp"
  field :recog_rdp, 8, type: NetprobeRecogMatchV1, json_name: "recogRdp"
  field :recog_dns, 9, type: NetprobeRecogMatchV1, json_name: "recogDns"
  field :recog_ntp, 10, type: NetprobeRecogMatchV1, json_name: "recogNtp"
end

defmodule Serviceradar.Edge.V1.NetprobeRecogMatchV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.NetprobeRecogMatchV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :product, 1, type: :string
  field :version, 2, type: :string
  field :os_family, 3, type: :string, json_name: "osFamily"
end

defmodule Serviceradar.Edge.V1.NetprobeOsMatchV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.NetprobeOsMatchV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :version_range, 2, type: :string, json_name: "versionRange"
  field :os_family, 3, type: :string, json_name: "osFamily"
  field :confidence, 4, type: :float
end

defmodule Serviceradar.Edge.V1.NetprobeDpiObservationV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.NetprobeDpiObservationV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :source, 1, type: :string
  field :profile_id, 2, type: :string, json_name: "profileId"
  field :profile_name, 3, type: :string, json_name: "profileName"
  field :interface_name, 4, type: :string, json_name: "interfaceName"
  field :protocol, 5, type: :string
  field :count, 6, type: :uint64
  field :confidence, 7, type: :float
  field :observed_at_unix_nano, 8, type: :int64, json_name: "observedAtUnixNano"
  field :last_observed_at_unix_nano, 9, type: :int64, json_name: "lastObservedAtUnixNano"
end

defmodule Serviceradar.Edge.V1.NetprobeProcessSnapshotObservationV1.ProtocolPortCountsEntry do
  @moduledoc false

  use Protobuf,
    full_name:
      "serviceradar.edge.v1.NetprobeProcessSnapshotObservationV1.ProtocolPortCountsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :uint32
end

defmodule Serviceradar.Edge.V1.NetprobeProcessSnapshotObservationV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.NetprobeProcessSnapshotObservationV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :schema, 1, type: :string
  field :fingerprint, 2, type: :string
  field :observed_at_unix_nano, 3, type: :int64, json_name: "observedAtUnixNano"
  field :entry_count, 4, type: :uint32, json_name: "entryCount"
  field :process_count, 5, type: :uint32, json_name: "processCount"
  field :port_count, 6, type: :uint32, json_name: "portCount"
  field :container_count, 7, type: :uint32, json_name: "containerCount"
  field :protocols, 8, repeated: true, type: :string

  field :protocol_port_counts, 9,
    repeated: true,
    type: Serviceradar.Edge.V1.NetprobeProcessSnapshotObservationV1.ProtocolPortCountsEntry,
    json_name: "protocolPortCounts",
    map: true
end

defmodule Serviceradar.Edge.V1.SyncPageBatchV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SyncPageBatchV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :sync_meta, 1, type: Serviceradar.Edge.V1.SyncMetaV1, json_name: "syncMeta"

  field :control_marker, 2,
    proto3_optional: true,
    type: Serviceradar.Edge.V1.SyncControlMarkerV1,
    json_name: "controlMarker"

  field :devices, 3, repeated: true, type: Serviceradar.Edge.V1.SyncDeviceRecordV1
end

defmodule Serviceradar.Edge.V1.SyncMetaV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SyncMetaV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :sync_service_id, 1, type: :string, json_name: "syncServiceId"
  field :sync_run_id, 2, type: :string, json_name: "syncRunId"
  field :chunk_index, 3, type: :int32, json_name: "chunkIndex"
  field :total_chunks, 4, type: :int32, json_name: "totalChunks"
  field :total_devices, 5, type: :int32, json_name: "totalDevices"
  field :is_final, 6, type: :bool, json_name: "isFinal"
  field :population, 7, type: Serviceradar.Edge.V1.SyncPopulationReportV1
end

defmodule Serviceradar.Edge.V1.SyncPopulationReportV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SyncPopulationReportV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :raw_rows, 1, type: :int64, json_name: "rawRows"
  field :excluded_rows, 2, type: :int64, json_name: "excludedRows"
  field :invalid_rows, 3, type: :int64, json_name: "invalidRows"
  field :valid_occurrences, 4, type: :int64, json_name: "validOccurrences"
  field :distinct_source_ids, 5, type: :int64, json_name: "distinctSourceIds"
  field :duplicate_occurrences, 6, type: :int64, json_name: "duplicateOccurrences"
  field :conflicting_duplicate_ids, 7, type: :int64, json_name: "conflictingDuplicateIds"

  field :duplicate_source_id_examples, 8,
    repeated: true,
    type: :string,
    json_name: "duplicateSourceIdExamples"

  field :invalid_row_examples, 9, repeated: true, type: :string, json_name: "invalidRowExamples"

  field :conflicting_duplicate_examples, 10,
    repeated: true,
    type: :string,
    json_name: "conflictingDuplicateExamples"
end

defmodule Serviceradar.Edge.V1.SyncControlMarkerV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SyncControlMarkerV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :control_type, 1, type: :string, json_name: "controlType"
  field :timestamp_unix_nano, 2, type: :int64, json_name: "timestampUnixNano"
end

defmodule Serviceradar.Edge.V1.SyncDeviceRecordV1.SwitchPortAttachmentEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SyncDeviceRecordV1.SwitchPortAttachmentEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Edge.V1.SyncDeviceRecordV1.MetadataEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SyncDeviceRecordV1.MetadataEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Edge.V1.SyncDeviceRecordV1.TagsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SyncDeviceRecordV1.TagsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Edge.V1.SyncDeviceRecordV1.FactsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SyncDeviceRecordV1.FactsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Edge.V1.SyncDeviceRecordV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SyncDeviceRecordV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :device_id, 1, type: :string, json_name: "deviceId"
  field :uid, 2, type: :string
  field :uid_alt, 3, type: :string, json_name: "uidAlt"
  field :agent_id, 4, type: :string, json_name: "agentId"
  field :gateway_id, 5, type: :string, json_name: "gatewayId"
  field :partition, 6, type: :string
  field :ip, 7, type: :string
  field :mac, 8, type: :string
  field :hostname, 9, type: :string
  field :name, 10, type: :string
  field :source, 11, type: :string
  field :source_instance, 12, type: :string, json_name: "sourceInstance"
  field :discovery_sources, 13, repeated: true, type: :string, json_name: "discoverySources"
  field :type, 14, type: :string
  field :type_id, 15, type: :int32, json_name: "typeId"
  field :device_type, 16, type: :string, json_name: "deviceType"
  field :vendor_name, 17, type: :string, json_name: "vendorName"
  field :model, 18, type: :string
  field :domain, 19, type: :string
  field :zone, 20, type: :string
  field :subnet_uid, 21, type: :string, json_name: "subnetUid"
  field :vlan_uid, 22, type: :string, json_name: "vlanUid"
  field :region, 23, type: :string
  field :os, 24, type: Serviceradar.Edge.V1.SyncDeviceOsV1
  field :hw_info, 27, type: Serviceradar.Edge.V1.SyncDeviceHwInfoV1, json_name: "hwInfo"
  field :risk_level_id, 28, proto3_optional: true, type: :int32, json_name: "riskLevelId"
  field :risk_level, 29, type: :string, json_name: "riskLevel"
  field :risk_score, 30, proto3_optional: true, type: :int32, json_name: "riskScore"
  field :is_available, 31, proto3_optional: true, type: :bool, json_name: "isAvailable"
  field :is_managed, 32, proto3_optional: true, type: :bool, json_name: "isManaged"
  field :is_compliant, 33, proto3_optional: true, type: :bool, json_name: "isCompliant"
  field :is_trusted, 34, proto3_optional: true, type: :bool, json_name: "isTrusted"
  field :timestamp_unix_nano, 38, type: :int64, json_name: "timestampUnixNano"
  field :first_seen_unix_nano, 39, type: :int64, json_name: "firstSeenUnixNano"
  field :last_seen_unix_nano, 40, type: :int64, json_name: "lastSeenUnixNano"
  field :created_time_unix_nano, 41, type: :int64, json_name: "createdTimeUnixNano"
  field :modified_time_unix_nano, 42, type: :int64, json_name: "modifiedTimeUnixNano"

  field :network_interfaces, 43,
    repeated: true,
    type: Serviceradar.Edge.V1.SyncNetworkInterfaceV1,
    json_name: "networkInterfaces"

  field :owner, 44, type: Serviceradar.Edge.V1.SyncDeviceUserV1
  field :org, 45, type: Serviceradar.Edge.V1.SyncDeviceOrganizationV1
  field :groups, 46, repeated: true, type: Serviceradar.Edge.V1.SyncDeviceGroupV1

  field :agent_list, 47,
    repeated: true,
    type: Serviceradar.Edge.V1.SyncDeviceAgentV1,
    json_name: "agentList"

  field :switch_port_attachment, 48,
    repeated: true,
    type: Serviceradar.Edge.V1.SyncDeviceRecordV1.SwitchPortAttachmentEntry,
    json_name: "switchPortAttachment",
    map: true

  field :metadata, 49,
    repeated: true,
    type: Serviceradar.Edge.V1.SyncDeviceRecordV1.MetadataEntry,
    map: true

  field :tags, 50,
    repeated: true,
    type: Serviceradar.Edge.V1.SyncDeviceRecordV1.TagsEntry,
    map: true

  field :facts, 51,
    repeated: true,
    type: Serviceradar.Edge.V1.SyncDeviceRecordV1.FactsEntry,
    map: true

  field :sync_meta, 52, type: Serviceradar.Edge.V1.SyncMetaV1, json_name: "syncMeta"
end

defmodule Serviceradar.Edge.V1.SyncDeviceOsV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SyncDeviceOsV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :type, 2, type: :string
  field :type_id, 3, proto3_optional: true, type: :int32, json_name: "typeId"
  field :version, 4, type: :string
  field :build, 5, type: :string
  field :edition, 6, type: :string
  field :kernel_release, 7, type: :string, json_name: "kernelRelease"
  field :cpu_bits, 8, proto3_optional: true, type: :int32, json_name: "cpuBits"
  field :sp_name, 9, type: :string, json_name: "spName"
  field :sp_ver, 10, type: :string, json_name: "spVer"
  field :lang, 11, type: :string
end

defmodule Serviceradar.Edge.V1.SyncDeviceHwInfoV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SyncDeviceHwInfoV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :cpu_architecture, 1, type: :string, json_name: "cpuArchitecture"
  field :cpu_bits, 2, proto3_optional: true, type: :int32, json_name: "cpuBits"
  field :cpu_cores, 3, proto3_optional: true, type: :int32, json_name: "cpuCores"
  field :cpu_count, 4, proto3_optional: true, type: :int32, json_name: "cpuCount"
  field :cpu_speed_mhz, 5, proto3_optional: true, type: :int32, json_name: "cpuSpeedMhz"
  field :cpu_type, 6, type: :string, json_name: "cpuType"
  field :ram_size, 7, proto3_optional: true, type: :int64, json_name: "ramSize"
  field :serial_number, 8, type: :string, json_name: "serialNumber"
  field :chassis, 9, type: :string
  field :bios_manufacturer, 10, type: :string, json_name: "biosManufacturer"
  field :bios_ver, 11, type: :string, json_name: "biosVer"
  field :bios_date, 12, type: :string, json_name: "biosDate"
  field :uuid, 13, type: :string
end

defmodule Serviceradar.Edge.V1.SyncNetworkInterfaceV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SyncNetworkInterfaceV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :description, 2, type: :string
  field :alias, 3, type: :string
  field :mac_address, 4, type: :string, json_name: "macAddress"
  field :ipv4_address, 5, type: :string, json_name: "ipv4Address"
  field :ipv6_address, 6, type: :string, json_name: "ipv6Address"
  field :ip_addresses, 7, repeated: true, type: :string, json_name: "ipAddresses"
  field :cidr, 8, type: :string
  field :subnet, 9, type: :string
  field :hostname, 10, type: :string
  field :uid, 11, type: :string
  field :type, 12, type: :string
  field :type_id, 13, proto3_optional: true, type: :int32, json_name: "typeId"
  field :brand, 14, type: :string
  field :broadcast_ssid, 15, type: :string, json_name: "broadcastSsid"

  field :hidden_broadcast_ssid, 16,
    proto3_optional: true,
    type: :bool,
    json_name: "hiddenBroadcastSsid"

  field :last_connected_ssid, 17, type: :string, json_name: "lastConnectedSsid"
  field :channels, 18, repeated: true, type: :string
  field :vlan, 19, proto3_optional: true, type: :int32
end

defmodule Serviceradar.Edge.V1.SyncDeviceUserV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SyncDeviceUserV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :uid, 1, type: :string
  field :name, 2, type: :string
  field :email, 3, type: :string
  field :type, 4, type: :string
  field :type_id, 5, proto3_optional: true, type: :int32, json_name: "typeId"
end

defmodule Serviceradar.Edge.V1.SyncDeviceOrganizationV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SyncDeviceOrganizationV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :uid, 1, type: :string
  field :name, 2, type: :string
  field :ou_uid, 3, type: :string, json_name: "ouUid"
  field :ou_name, 4, type: :string, json_name: "ouName"
end

defmodule Serviceradar.Edge.V1.SyncDeviceGroupV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SyncDeviceGroupV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :uid, 1, type: :string
  field :name, 2, type: :string
  field :type, 3, type: :string
  field :desc, 4, type: :string
end

defmodule Serviceradar.Edge.V1.SyncDeviceAgentV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SyncDeviceAgentV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :uid, 1, type: :string
  field :name, 2, type: :string
  field :type, 3, type: :string
  field :type_id, 4, proto3_optional: true, type: :int32, json_name: "typeId"
  field :version, 5, type: :string
  field :vendor_name, 6, type: :string, json_name: "vendorName"
end
