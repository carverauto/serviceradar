defmodule Monitoring.SNMPVersion do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "monitoring.SNMPVersion",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :SNMP_VERSION_UNSPECIFIED, 0
  field :SNMP_VERSION_V1, 1
  field :SNMP_VERSION_V2C, 2
  field :SNMP_VERSION_V3, 3
end

defmodule Monitoring.SNMPSecurityLevel do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "monitoring.SNMPSecurityLevel",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :SNMP_SECURITY_LEVEL_UNSPECIFIED, 0
  field :SNMP_SECURITY_LEVEL_NO_AUTH_NO_PRIV, 1
  field :SNMP_SECURITY_LEVEL_AUTH_NO_PRIV, 2
  field :SNMP_SECURITY_LEVEL_AUTH_PRIV, 3
end

defmodule Monitoring.SNMPAuthProtocol do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "monitoring.SNMPAuthProtocol",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :SNMP_AUTH_PROTOCOL_UNSPECIFIED, 0
  field :SNMP_AUTH_PROTOCOL_MD5, 1
  field :SNMP_AUTH_PROTOCOL_SHA, 2
  field :SNMP_AUTH_PROTOCOL_SHA224, 3
  field :SNMP_AUTH_PROTOCOL_SHA256, 4
  field :SNMP_AUTH_PROTOCOL_SHA384, 5
  field :SNMP_AUTH_PROTOCOL_SHA512, 6
end

defmodule Monitoring.SNMPPrivProtocol do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "monitoring.SNMPPrivProtocol",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :SNMP_PRIV_PROTOCOL_UNSPECIFIED, 0
  field :SNMP_PRIV_PROTOCOL_DES, 1
  field :SNMP_PRIV_PROTOCOL_AES, 2
  field :SNMP_PRIV_PROTOCOL_AES192, 3
  field :SNMP_PRIV_PROTOCOL_AES256, 4
  field :SNMP_PRIV_PROTOCOL_AES192C, 5
  field :SNMP_PRIV_PROTOCOL_AES256C, 6
end

defmodule Monitoring.SNMPDataType do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "monitoring.SNMPDataType",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :SNMP_DATA_TYPE_UNSPECIFIED, 0
  field :SNMP_DATA_TYPE_COUNTER, 1
  field :SNMP_DATA_TYPE_GAUGE, 2
  field :SNMP_DATA_TYPE_BOOLEAN, 3
  field :SNMP_DATA_TYPE_BYTES, 4
  field :SNMP_DATA_TYPE_STRING, 5
  field :SNMP_DATA_TYPE_FLOAT, 6
  field :SNMP_DATA_TYPE_TIMETICKS, 7
end

defmodule Monitoring.SweepCompletionStatus.Status do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "monitoring.SweepCompletionStatus.Status",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :UNKNOWN, 0
  field :NOT_STARTED, 1
  field :IN_PROGRESS, 2
  field :COMPLETED, 3
  field :FAILED, 4
end

defmodule Monitoring.DeviceStatusRequest do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.DeviceStatusRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :agent_id, 1, type: :string, json_name: "agentId"
end

defmodule Monitoring.StatusRequest do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.StatusRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :service_name, 1, type: :string, json_name: "serviceName"
  field :service_type, 2, type: :string, json_name: "serviceType"
  field :agent_id, 3, type: :string, json_name: "agentId"
  field :gateway_id, 4, type: :string, json_name: "gatewayId"
  field :details, 5, type: :string
  field :port, 6, type: :int32
end

defmodule Monitoring.ResultsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.ResultsRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :service_name, 1, type: :string, json_name: "serviceName"
  field :service_type, 2, type: :string, json_name: "serviceType"
  field :agent_id, 3, type: :string, json_name: "agentId"
  field :gateway_id, 4, type: :string, json_name: "gatewayId"
  field :details, 5, type: :string
  field :last_sequence, 6, type: :string, json_name: "lastSequence"

  field :completion_status, 7,
    type: Monitoring.SweepCompletionStatus,
    json_name: "completionStatus"
end

defmodule Monitoring.StatusResponse do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.StatusResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :available, 1, type: :bool
  field :message, 2, type: :bytes
  field :service_name, 3, type: :string, json_name: "serviceName"
  field :service_type, 4, type: :string, json_name: "serviceType"
  field :response_time, 5, type: :int64, json_name: "responseTime"
  field :agent_id, 6, type: :string, json_name: "agentId"
  field :gateway_id, 7, type: :string, json_name: "gatewayId"
  field :sidecars, 8, repeated: true, type: Monitoring.SidecarStatus
end

defmodule Monitoring.SidecarStatus do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.SidecarStatus",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :state, 2, type: :string
  field :pid, 3, type: :int32
  field :last_health_at, 4, type: :int64, json_name: "lastHealthAt"
  field :restart_count, 5, type: :uint32, json_name: "restartCount"
  field :last_error, 6, type: :string, json_name: "lastError"
  field :version, 7, type: :string
  field :arch, 8, type: :string
end

defmodule Monitoring.ResultsResponse do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.ResultsResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :available, 1, type: :bool
  field :data, 2, type: :bytes
  field :service_name, 3, type: :string, json_name: "serviceName"
  field :service_type, 4, type: :string, json_name: "serviceType"
  field :response_time, 5, type: :int64, json_name: "responseTime"
  field :agent_id, 6, type: :string, json_name: "agentId"
  field :gateway_id, 7, type: :string, json_name: "gatewayId"
  field :timestamp, 8, type: :int64
  field :current_sequence, 9, type: :string, json_name: "currentSequence"
  field :has_new_data, 10, type: :bool, json_name: "hasNewData"

  field :sweep_completion, 11,
    type: Monitoring.SweepCompletionStatus,
    json_name: "sweepCompletion"

  field :execution_id, 12, type: :string, json_name: "executionId"
  field :sweep_group_id, 13, type: :string, json_name: "sweepGroupId"
end

defmodule Monitoring.SweepServiceStatus do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.SweepServiceStatus",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :network, 1, type: :string
  field :total_hosts, 2, type: :int32, json_name: "totalHosts"
  field :available_hosts, 3, type: :int32, json_name: "availableHosts"
  field :ports, 4, repeated: true, type: Monitoring.PortStatus
  field :last_sweep, 5, type: :int64, json_name: "lastSweep"
end

defmodule Monitoring.PortStatus do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.PortStatus",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :port, 1, type: :int32
  field :available, 2, type: :int32
end

defmodule Monitoring.ResultsChunk do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.ResultsChunk",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :data, 1, type: :bytes
  field :is_final, 2, type: :bool, json_name: "isFinal"
  field :chunk_index, 3, type: :int32, json_name: "chunkIndex"
  field :total_chunks, 4, type: :int32, json_name: "totalChunks"
  field :current_sequence, 5, type: :string, json_name: "currentSequence"
  field :timestamp, 6, type: :int64
end

defmodule Monitoring.SweepCompletionStatus do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.SweepCompletionStatus",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :status, 1, type: Monitoring.SweepCompletionStatus.Status, enum: true
  field :completion_time, 2, type: :int64, json_name: "completionTime"
  field :target_sequence, 3, type: :string, json_name: "targetSequence"
  field :total_targets, 4, type: :int32, json_name: "totalTargets"
  field :completed_targets, 5, type: :int32, json_name: "completedTargets"
  field :error_message, 6, type: :string, json_name: "errorMessage"
  field :execution_id, 7, type: :string, json_name: "executionId"
  field :sweep_group_id, 8, type: :string, json_name: "sweepGroupId"
  field :scanner_stats, 9, type: Monitoring.SweepScannerStats, json_name: "scannerStats"
end

defmodule Monitoring.SweepScannerStats do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.SweepScannerStats",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :packets_sent, 1, type: :uint64, json_name: "packetsSent"
  field :packets_recv, 2, type: :uint64, json_name: "packetsRecv"
  field :packets_dropped, 3, type: :uint64, json_name: "packetsDropped"
  field :ring_blocks_processed, 4, type: :uint64, json_name: "ringBlocksProcessed"
  field :ring_blocks_dropped, 5, type: :uint64, json_name: "ringBlocksDropped"
  field :retries_attempted, 6, type: :uint64, json_name: "retriesAttempted"
  field :retries_successful, 7, type: :uint64, json_name: "retriesSuccessful"
  field :ports_allocated, 8, type: :uint64, json_name: "portsAllocated"
  field :ports_released, 9, type: :uint64, json_name: "portsReleased"
  field :port_exhaustion_count, 10, type: :uint64, json_name: "portExhaustionCount"
  field :rate_limit_deferrals, 11, type: :uint64, json_name: "rateLimitDeferrals"
  field :rx_drop_rate_percent, 12, type: :double, json_name: "rxDropRatePercent"
  field :rate_limit_waits, 13, type: :uint64, json_name: "rateLimitWaits"
  field :source_port_waits, 14, type: :uint64, json_name: "sourcePortWaits"
  field :rate_limit_wait_time_ms, 15, type: :uint64, json_name: "rateLimitWaitTimeMs"
  field :source_port_wait_time_ms, 16, type: :uint64, json_name: "sourcePortWaitTimeMs"
  field :protocol, 17, type: :string
  field :address_family, 18, type: :string, json_name: "addressFamily"
  field :scanner_path, 19, type: :string, json_name: "scannerPath"
  field :dials_started, 20, type: :uint64, json_name: "dialsStarted"
  field :dials_succeeded, 21, type: :uint64, json_name: "dialsSucceeded"
  field :dial_timeouts, 22, type: :uint64, json_name: "dialTimeouts"
  field :dial_resets, 23, type: :uint64, json_name: "dialResets"
  field :dial_resource_errors, 24, type: :uint64, json_name: "dialResourceErrors"
  field :active_dials, 25, type: :uint64, json_name: "activeDials"
  field :max_active_dials, 26, type: :uint64, json_name: "maxActiveDials"
  field :queue_depth, 27, type: :uint64, json_name: "queueDepth"
  field :max_queue_depth, 28, type: :uint64, json_name: "maxQueueDepth"
end

defmodule Monitoring.GatewayStatusRequest do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.GatewayStatusRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :services, 1, repeated: true, type: Monitoring.GatewayServiceStatus
  field :gateway_id, 2, type: :string, json_name: "gatewayId"
  field :agent_id, 3, type: :string, json_name: "agentId"
  field :timestamp, 4, type: :int64
  field :partition, 5, type: :string
  field :source_ip, 6, type: :string, json_name: "sourceIp"
  field :kv_store_id, 7, type: :string, json_name: "kvStoreId"
  field :config_source, 10, type: :string, json_name: "configSource"
  field :version, 11, type: :string
  field :hostname, 12, type: :string
  field :os, 13, type: :string
  field :arch, 14, type: :string

  field :endpoint_inventory_standing_question_counts, 15,
    repeated: true,
    type: Monitoring.EndpointInventoryStandingQuestionResultCount,
    json_name: "endpointInventoryStandingQuestionCounts"
end

defmodule Monitoring.GatewayStatusResponse do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.GatewayStatusResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :received, 1, type: :bool
  field :directives, 2, repeated: true, type: Monitoring.GatewayStatusDirective
end

defmodule Monitoring.GatewayStatusDirective do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.GatewayStatusDirective",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :service_name, 1, type: :string, json_name: "serviceName"
  field :service_type, 2, type: :string, json_name: "serviceType"
  field :directive_type, 3, type: :string, json_name: "directiveType"
  field :payload_json, 4, type: :bytes, json_name: "payloadJson"
end

defmodule Monitoring.GatewayStatusChunk do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.GatewayStatusChunk",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :services, 1, repeated: true, type: Monitoring.GatewayServiceStatus
  field :gateway_id, 2, type: :string, json_name: "gatewayId"
  field :agent_id, 3, type: :string, json_name: "agentId"
  field :timestamp, 4, type: :int64
  field :partition, 5, type: :string
  field :source_ip, 6, type: :string, json_name: "sourceIp"
  field :is_final, 7, type: :bool, json_name: "isFinal"
  field :chunk_index, 8, type: :int32, json_name: "chunkIndex"
  field :total_chunks, 9, type: :int32, json_name: "totalChunks"
  field :kv_store_id, 10, type: :string, json_name: "kvStoreId"
  field :config_source, 13, type: :string, json_name: "configSource"
  field :version, 14, type: :string
  field :hostname, 15, type: :string
  field :os, 16, type: :string
  field :arch, 17, type: :string

  field :endpoint_inventory_standing_question_counts, 18,
    repeated: true,
    type: Monitoring.EndpointInventoryStandingQuestionResultCount,
    json_name: "endpointInventoryStandingQuestionCounts"

  field :capabilities, 19, repeated: true, type: :string
end

defmodule Monitoring.GatewayServiceStatus do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.GatewayServiceStatus",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :service_name, 1, type: :string, json_name: "serviceName"
  field :available, 2, type: :bool
  field :message, 3, type: :bytes
  field :service_type, 4, type: :string, json_name: "serviceType"
  field :response_time, 5, type: :int64, json_name: "responseTime"
  field :agent_id, 6, type: :string, json_name: "agentId"
  field :gateway_id, 7, type: :string, json_name: "gatewayId"
  field :partition, 8, type: :string
  field :source, 9, type: :string
  field :kv_store_id, 10, type: :string, json_name: "kvStoreId"
end

defmodule Monitoring.AgentHelloRequest.LabelsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.AgentHelloRequest.LabelsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Monitoring.AgentHelloRequest do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.AgentHelloRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :agent_id, 1, type: :string, json_name: "agentId"
  field :version, 2, type: :string
  field :capabilities, 3, repeated: true, type: :string
  field :hostname, 4, type: :string
  field :os, 5, type: :string
  field :arch, 6, type: :string
  field :partition, 7, type: :string
  field :config_version, 8, type: :string, json_name: "configVersion"
  field :labels, 9, repeated: true, type: Monitoring.AgentHelloRequest.LabelsEntry, map: true
  field :config_source, 10, type: :string, json_name: "configSource"
  field :host_ip, 11, type: :string, json_name: "hostIp"
end

defmodule Monitoring.AgentHelloResponse do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.AgentHelloResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :accepted, 1, type: :bool
  field :agent_id, 2, type: :string, json_name: "agentId"
  field :message, 3, type: :string
  field :gateway_id, 4, type: :string, json_name: "gatewayId"
  field :server_time, 5, type: :int64, json_name: "serverTime"
  field :heartbeat_interval_sec, 6, type: :int32, json_name: "heartbeatIntervalSec"
  field :config_outdated, 7, type: :bool, json_name: "configOutdated"
end

defmodule Monitoring.AgentConfigRequest do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.AgentConfigRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :agent_id, 1, type: :string, json_name: "agentId"
  field :config_version, 2, type: :string, json_name: "configVersion"
end

defmodule Monitoring.AgentConfigResponse do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.AgentConfigResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :not_modified, 1, type: :bool, json_name: "notModified"
  field :config_version, 2, type: :string, json_name: "configVersion"
  field :config_timestamp, 3, type: :int64, json_name: "configTimestamp"
  field :heartbeat_interval_sec, 4, type: :int32, json_name: "heartbeatIntervalSec"
  field :config_poll_interval_sec, 5, type: :int32, json_name: "configPollIntervalSec"
  field :checks, 6, repeated: true, type: Monitoring.AgentCheckConfig
  field :config_json, 7, type: :bytes, json_name: "configJson"
  field :sysmon_config, 8, type: Monitoring.SysmonConfig, json_name: "sysmonConfig"
  field :snmp_config, 9, type: Monitoring.SNMPConfig, json_name: "snmpConfig"
  field :visibility_config, 10, type: Monitoring.VisibilityConfig, json_name: "visibilityConfig"
  field :plugin_config, 11, type: Monitoring.PluginConfig, json_name: "pluginConfig"
  field :bumblebee_config, 12, type: Monitoring.BumblebeeConfig, json_name: "bumblebeeConfig"
  field :addons, 13, repeated: true, type: Monitoring.AddonAssignmentConfig

  field :endpoint_inventory_config, 14,
    type: Monitoring.EndpointInventoryConfig,
    json_name: "endpointInventoryConfig"
end

defmodule Monitoring.AddonAssignmentConfig do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.AddonAssignmentConfig",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :addon_id, 1, type: :string, json_name: "addonId"
  field :version, 2, type: :string
  field :enabled, 3, type: :bool
  field :binary_path, 4, type: :string, json_name: "binaryPath"
  field :args, 5, repeated: true, type: :string
  field :config_json, 6, type: :bytes, json_name: "configJson"
  field :capabilities, 7, repeated: true, type: :string
  field :delivery, 8, type: :string
  field :supervision, 9, type: :string
  field :artifact_object_key, 10, type: :string, json_name: "artifactObjectKey"
  field :artifact_sha256, 11, type: :string, json_name: "artifactSha256"
  field :artifact_signature, 12, type: :string, json_name: "artifactSignature"
  field :target_os, 13, type: :string, json_name: "targetOs"
  field :target_arch, 14, type: :string, json_name: "targetArch"
  field :os_capabilities, 15, repeated: true, type: :string, json_name: "osCapabilities"
  field :download_url, 16, type: :string, json_name: "downloadUrl"
  field :download_token, 17, type: :string, json_name: "downloadToken"
  field :resources, 18, type: Monitoring.AddonResources
end

defmodule Monitoring.AddonResources do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.AddonResources",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :cpu_max_percent, 1, type: :double, json_name: "cpuMaxPercent"
  field :memory_max_bytes, 2, type: :int64, json_name: "memoryMaxBytes"
  field :memory_high_bytes, 3, type: :int64, json_name: "memoryHighBytes"
  field :tasks_max, 4, type: :int64, json_name: "tasksMax"
  field :slice, 5, type: :string
end

defmodule Monitoring.AgentConfigChunk do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.AgentConfigChunk",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :agent_id, 1, type: :string, json_name: "agentId"
  field :config_version, 2, type: :string, json_name: "configVersion"
  field :config_timestamp, 3, type: :int64, json_name: "configTimestamp"
  field :not_modified, 4, type: :bool, json_name: "notModified"
  field :payload, 5, type: :bytes
  field :is_final, 6, type: :bool, json_name: "isFinal"
  field :chunk_index, 7, type: :int32, json_name: "chunkIndex"
  field :total_chunks, 8, type: :int32, json_name: "totalChunks"
  field :payload_sha256, 9, type: :string, json_name: "payloadSha256"
end

defmodule Monitoring.ControlStreamHello.LabelsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.ControlStreamHello.LabelsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Monitoring.ControlStreamHello do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.ControlStreamHello",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :agent_id, 1, type: :string, json_name: "agentId"
  field :partition, 2, type: :string
  field :capabilities, 3, repeated: true, type: :string
  field :config_version, 4, type: :string, json_name: "configVersion"
  field :version, 5, type: :string
  field :hostname, 6, type: :string
  field :os, 7, type: :string
  field :arch, 8, type: :string
  field :labels, 9, repeated: true, type: Monitoring.ControlStreamHello.LabelsEntry, map: true
  field :config_source, 10, type: :string, json_name: "configSource"
  field :host_ip, 11, type: :string, json_name: "hostIp"

  field :applied_plugin_assignments, 12,
    repeated: true,
    type: Monitoring.PluginAssignmentPolicyAck,
    json_name: "appliedPluginAssignments"
end

defmodule Monitoring.CommandRequest do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.CommandRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :command_id, 1, type: :string, json_name: "commandId"
  field :command_type, 2, type: :string, json_name: "commandType"
  field :payload_json, 3, type: :bytes, json_name: "payloadJson"
  field :ttl_seconds, 4, type: :int64, json_name: "ttlSeconds"
  field :created_at, 5, type: :int64, json_name: "createdAt"
end

defmodule Monitoring.CommandAck do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.CommandAck",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :command_id, 1, type: :string, json_name: "commandId"
  field :command_type, 2, type: :string, json_name: "commandType"
  field :timestamp, 3, type: :int64
  field :message, 4, type: :string
end

defmodule Monitoring.CommandProgress do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.CommandProgress",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :command_id, 1, type: :string, json_name: "commandId"
  field :command_type, 2, type: :string, json_name: "commandType"
  field :progress_percent, 3, type: :int32, json_name: "progressPercent"
  field :message, 4, type: :string
  field :timestamp, 5, type: :int64
  field :payload_json, 6, type: :bytes, json_name: "payloadJson"
end

defmodule Monitoring.CommandResult do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.CommandResult",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :command_id, 1, type: :string, json_name: "commandId"
  field :command_type, 2, type: :string, json_name: "commandType"
  field :success, 3, type: :bool
  field :message, 4, type: :string
  field :payload_json, 5, type: :bytes, json_name: "payloadJson"
  field :timestamp, 6, type: :int64
end

defmodule Monitoring.ConfigSectionStatus do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.ConfigSectionStatus",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :section, 1, type: :string
  field :disposition, 2, type: :string
  field :error, 3, type: :string
  field :since, 4, type: :int64
end

defmodule Monitoring.ConfigAck do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.ConfigAck",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :config_version, 1, type: :string, json_name: "configVersion"
  field :timestamp, 2, type: :int64

  field :section_statuses, 3,
    repeated: true,
    type: Monitoring.ConfigSectionStatus,
    json_name: "sectionStatuses"

  field :applied_plugin_assignments, 4,
    repeated: true,
    type: Monitoring.PluginAssignmentPolicyAck,
    json_name: "appliedPluginAssignments"
end

defmodule Monitoring.PluginAssignmentPolicyAck do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.PluginAssignmentPolicyAck",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :assignment_id, 1, type: :string, json_name: "assignmentId"
  field :plugin_id, 2, type: :string, json_name: "pluginId"
  field :assignment_policy_version, 3, type: :uint64, json_name: "assignmentPolicyVersion"
  field :assignment_policy_fingerprint, 4, type: :string, json_name: "assignmentPolicyFingerprint"
end

defmodule Monitoring.ConsoleFrame do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.ConsoleFrame",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :session_id, 1, type: :string, json_name: "sessionId"
  field :frame_type, 2, type: :string, json_name: "frameType"
  field :data, 3, type: :bytes
  field :cols, 4, type: :uint32
  field :rows, 5, type: :uint32
  field :reason, 6, type: :string
  field :timestamp, 7, type: :int64
  field :seq, 8, type: :uint64
  field :payload_sha256, 9, type: :string, json_name: "payloadSha256"
  field :signature, 10, type: :string
  field :assignment_policy_version, 11, type: :uint64, json_name: "assignmentPolicyVersion"

  field :assignment_policy_fingerprint, 12,
    type: :string,
    json_name: "assignmentPolicyFingerprint"
end

defmodule Monitoring.ControlStreamRequest do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.ControlStreamRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof(:payload, 0)

  field :hello, 1, type: Monitoring.ControlStreamHello, oneof: 0
  field :command_ack, 2, type: Monitoring.CommandAck, json_name: "commandAck", oneof: 0

  field :command_progress, 3,
    type: Monitoring.CommandProgress,
    json_name: "commandProgress",
    oneof: 0

  field :command_result, 4, type: Monitoring.CommandResult, json_name: "commandResult", oneof: 0
  field :config_ack, 5, type: Monitoring.ConfigAck, json_name: "configAck", oneof: 0
  field :console_frame, 6, type: Monitoring.ConsoleFrame, json_name: "consoleFrame", oneof: 0
end

defmodule Monitoring.ControlStreamResponse do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.ControlStreamResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof(:payload, 0)

  field :command, 1, type: Monitoring.CommandRequest, oneof: 0
  field :config, 2, type: Monitoring.AgentConfigResponse, oneof: 0
  field :console_frame, 3, type: Monitoring.ConsoleFrame, json_name: "consoleFrame", oneof: 0
end

defmodule Monitoring.CredentialBrokerResolveRequest do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.CredentialBrokerResolveRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :agent_id, 1, type: :string, json_name: "agentId"
  field :grant_id, 2, type: :string, json_name: "grantId"
  field :credential_secret_ref, 3, type: :string, json_name: "credentialSecretRef"
  field :consumer_kind, 4, type: :string, json_name: "consumerKind"
  field :consumer_id, 5, type: :string, json_name: "consumerId"
  field :purpose, 6, type: :string
  field :resolution_location, 7, type: :string, json_name: "resolutionLocation"
end

defmodule Monitoring.CredentialBrokerResolveResponse.FieldsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.CredentialBrokerResolveResponse.FieldsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Monitoring.CredentialBrokerResolveResponse do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.CredentialBrokerResolveResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :success, 1, type: :bool
  field :message, 2, type: :string
  field :value, 3, type: :string

  field :fields, 4,
    repeated: true,
    type: Monitoring.CredentialBrokerResolveResponse.FieldsEntry,
    map: true

  field :source_type, 5, type: :string, json_name: "sourceType"
  field :lease_expires_at_unix, 6, type: :int64, json_name: "leaseExpiresAtUnix"
  field :cache_status, 7, type: :string, json_name: "cacheStatus"
end

defmodule Monitoring.PluginConfig do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.PluginConfig",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :assignments, 1, repeated: true, type: Monitoring.PluginAssignmentConfig
  field :engine_limits, 2, type: Monitoring.PluginEngineLimits, json_name: "engineLimits"
end

defmodule Monitoring.PluginEngineLimits do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.PluginEngineLimits",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :max_memory_mb, 1, type: :int32, json_name: "maxMemoryMb"
  field :max_cpu_ms, 2, type: :int32, json_name: "maxCpuMs"
  field :max_concurrent, 3, type: :int32, json_name: "maxConcurrent"
  field :max_open_connections, 4, type: :int32, json_name: "maxOpenConnections"
end

defmodule Monitoring.PluginAssignmentConfig do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.PluginAssignmentConfig",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :assignment_id, 1, type: :string, json_name: "assignmentId"
  field :plugin_id, 2, type: :string, json_name: "pluginId"
  field :package_id, 3, type: :string, json_name: "packageId"
  field :version, 4, type: :string
  field :name, 5, type: :string
  field :entrypoint, 6, type: :string
  field :runtime, 7, type: :string
  field :outputs, 8, type: :string
  field :capabilities, 9, repeated: true, type: :string
  field :params_json, 10, type: :bytes, json_name: "paramsJson"
  field :permissions_json, 11, type: :bytes, json_name: "permissionsJson"
  field :resources_json, 12, type: :bytes, json_name: "resourcesJson"
  field :enabled, 13, type: :bool
  field :interval_sec, 14, type: :int32, json_name: "intervalSec"
  field :timeout_sec, 15, type: :int32, json_name: "timeoutSec"
  field :wasm_object_key, 16, type: :string, json_name: "wasmObjectKey"
  field :content_hash, 17, type: :string, json_name: "contentHash"
  field :source_type, 18, type: :string, json_name: "sourceType"
  field :source_repo_url, 19, type: :string, json_name: "sourceRepoUrl"
  field :source_commit, 20, type: :string, json_name: "sourceCommit"
  field :download_url, 21, type: :string, json_name: "downloadUrl"
  field :download_token, 22, type: :string, json_name: "downloadToken"
  field :host_params_json, 23, type: :bytes, json_name: "hostParamsJson"
end

defmodule Monitoring.BumblebeeConfig do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.BumblebeeConfig",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :enabled, 1, type: :bool
  field :agent_id, 2, type: :string, json_name: "agentId"
  field :scan_profile, 3, type: :string, json_name: "scanProfile"
  field :root_discovery_mode, 4, type: :string, json_name: "rootDiscoveryMode"
  field :explicit_roots, 5, repeated: true, type: :string, json_name: "explicitRoots"
  field :exclude_roots, 6, repeated: true, type: :string, json_name: "excludeRoots"
  field :ecosystems, 7, repeated: true, type: :string
  field :scan_timeout, 8, type: :string, json_name: "scanTimeout"
  field :max_findings, 9, type: :int32, json_name: "maxFindings"
  field :max_output_bytes, 10, type: :int64, json_name: "maxOutputBytes"
  field :cadence, 11, type: :string
  field :findings_only, 12, type: :bool, json_name: "findingsOnly"
  field :catalog, 13, type: Monitoring.BumblebeeCatalogAssignment
end

defmodule Monitoring.BumblebeeCatalogAssignment do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.BumblebeeCatalogAssignment",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :schema_version, 1, type: :string, json_name: "schemaVersion"
  field :snapshot_ref, 2, type: :string, json_name: "snapshotRef"
  field :catalog_version, 3, type: :string, json_name: "catalogVersion"
  field :source_revision, 4, type: :string, json_name: "sourceRevision"
  field :object_key, 5, type: :string, json_name: "objectKey"
  field :sha256, 6, type: :string
  field :size_bytes, 7, type: :int64, json_name: "sizeBytes"
  field :promoted_at, 8, type: :string, json_name: "promotedAt"
end

defmodule Monitoring.EndpointInventoryConfig do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.EndpointInventoryConfig",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :enabled, 1, type: :bool
  field :agent_id, 2, type: :string, json_name: "agentId"
  field :sources, 3, repeated: true, type: :string
  field :scan_timeout, 4, type: :string, json_name: "scanTimeout"
  field :max_packages, 5, type: :int32, json_name: "maxPackages"
  field :max_output_bytes, 6, type: :int64, json_name: "maxOutputBytes"
  field :cadence, 7, type: :string
  field :collect_paths, 8, type: :bool, json_name: "collectPaths"
  field :collect_file_hashes, 9, type: :bool, json_name: "collectFileHashes"
  field :force_fresh_enabled, 10, type: :bool, json_name: "forceFreshEnabled"
  field :force_full_scan_interval, 11, type: :int32, json_name: "forceFullScanInterval"
  field :cache_stale_threshold, 12, type: :string, json_name: "cacheStaleThreshold"
  field :upload_jitter, 13, type: :string, json_name: "uploadJitter"
  field :upload_retry_initial, 14, type: :string, json_name: "uploadRetryInitial"
  field :upload_retry_max, 15, type: :string, json_name: "uploadRetryMax"
  field :upload_retry_max_attempts, 16, type: :int32, json_name: "uploadRetryMaxAttempts"
end

defmodule Monitoring.EndpointInventoryReport do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.EndpointInventoryReport",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :metadata, 1, type: Monitoring.EndpointInventoryScanMetadata
  field :artifact, 2, type: Monitoring.EndpointInventoryArtifactRef
  field :packages, 3, repeated: true, type: Monitoring.EndpointInventoryPackageSummary

  field :cohort_coverage, 4,
    type: Monitoring.EndpointInventoryCohortCoverage,
    json_name: "cohortCoverage"
end

defmodule Monitoring.EndpointInventoryScanMetadata.RedactionEntry do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.EndpointInventoryScanMetadata.RedactionEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Monitoring.EndpointInventoryScanMetadata do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.EndpointInventoryScanMetadata",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :schema_version, 1, type: :string, json_name: "schemaVersion"
  field :scan_id, 2, type: :string, json_name: "scanId"
  field :agent_id, 3, type: :string, json_name: "agentId"
  field :device_uid, 4, type: :string, json_name: "deviceUid"
  field :collector_name, 5, type: :string, json_name: "collectorName"
  field :collector_version, 6, type: :string, json_name: "collectorVersion"
  field :state, 7, type: :string
  field :coverage_state, 8, type: :string, json_name: "coverageState"
  field :scanned_at_unix, 9, type: :int64, json_name: "scannedAtUnix"
  field :last_successful_scan_at_unix, 10, type: :int64, json_name: "lastSuccessfulScanAtUnix"
  field :sources, 11, repeated: true, type: Monitoring.EndpointInventorySourceSummary
  field :package_count, 12, type: :int32, json_name: "packageCount"
  field :enabled_sources, 13, repeated: true, type: :string, json_name: "enabledSources"

  field :redaction, 14,
    repeated: true,
    type: Monitoring.EndpointInventoryScanMetadata.RedactionEntry,
    map: true

  field :ingestion_status, 15, type: :string, json_name: "ingestionStatus"
  field :ingestion_error, 16, type: :string, json_name: "ingestionError"
  field :package_set_hash, 17, type: :string, json_name: "packageSetHash"
  field :artifact_hash, 18, type: :string, json_name: "artifactHash"
  field :hash_algorithm, 19, type: :string, json_name: "hashAlgorithm"
  field :upload_reason, 20, type: :string, json_name: "uploadReason"
  field :last_changed_scan_at_unix, 21, type: :int64, json_name: "lastChangedScanAtUnix"
  field :unchanged_scan_count, 22, type: :int32, json_name: "unchangedScanCount"
  field :freshness, 23, type: Monitoring.EndpointInventoryFreshness
end

defmodule Monitoring.EndpointInventoryFreshness do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.EndpointInventoryFreshness",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :verdict, 1, type: :string
  field :age_seconds, 2, type: :int64, json_name: "ageSeconds"
  field :stale_threshold_seconds, 3, type: :int64, json_name: "staleThresholdSeconds"
  field :last_successful_scan_at_unix, 4, type: :int64, json_name: "lastSuccessfulScanAtUnix"
end

defmodule Monitoring.EndpointInventoryCohortCoverage do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.EndpointInventoryCohortCoverage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :targeted, 1, type: :int32
  field :answered, 2, type: :int32
  field :offline, 3, type: :int32
  field :expired, 4, type: :int32
  field :pending, 5, type: :int32
  field :rejected, 6, type: :int32
  field :rejection_reason, 7, type: :string, json_name: "rejectionReason"
end

defmodule Monitoring.EndpointInventorySourceSummary do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.EndpointInventorySourceSummary",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :source, 1, type: :string
  field :state, 2, type: :string
  field :package_count, 3, type: :int32, json_name: "packageCount"
  field :error, 4, type: :string
end

defmodule Monitoring.EndpointInventoryArtifactRef.MetadataEntry do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.EndpointInventoryArtifactRef.MetadataEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Monitoring.EndpointInventoryArtifactRef do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.EndpointInventoryArtifactRef",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :object_key, 1, type: :string, json_name: "objectKey"
  field :bucket, 2, type: :string
  field :domain, 3, type: :string
  field :content_type, 4, type: :string, json_name: "contentType"
  field :format, 5, type: :string
  field :spec_version, 6, type: :string, json_name: "specVersion"
  field :sha256, 7, type: :string
  field :size_bytes, 8, type: :int64, json_name: "sizeBytes"
  field :uploaded_at_unix, 9, type: :int64, json_name: "uploadedAtUnix"

  field :metadata, 10,
    repeated: true,
    type: Monitoring.EndpointInventoryArtifactRef.MetadataEntry,
    map: true
end

defmodule Monitoring.EndpointInventoryPackageSummary.EvidenceEntry do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.EndpointInventoryPackageSummary.EvidenceEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Monitoring.EndpointInventoryPackageSummary do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.EndpointInventoryPackageSummary",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :version, 2, type: :string
  field :architecture, 3, type: :string
  field :package_manager, 4, type: :string, json_name: "packageManager"
  field :ecosystem, 5, type: :string
  field :purl, 6, type: :string
  field :cpes, 7, repeated: true, type: :string
  field :supplier, 8, type: :string
  field :license, 9, type: :string
  field :source, 10, type: :string

  field :evidence, 11,
    repeated: true,
    type: Monitoring.EndpointInventoryPackageSummary.EvidenceEntry,
    map: true

  field :purl_canonical, 12, type: :string, json_name: "purlCanonical"
end

defmodule Monitoring.EndpointInventoryQueryRequest.MetadataEntry do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.EndpointInventoryQueryRequest.MetadataEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Monitoring.EndpointInventoryQueryRequest do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.EndpointInventoryQueryRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :schema, 1, type: :string
  field :mode, 2, type: :string
  field :predicate, 3, type: Monitoring.EndpointInventoryPackagePredicate
  field :limit, 4, type: :int32
  field :stale_threshold_seconds, 5, type: :int64, json_name: "staleThresholdSeconds"

  field :metadata, 6,
    repeated: true,
    type: Monitoring.EndpointInventoryQueryRequest.MetadataEntry,
    map: true
end

defmodule Monitoring.EndpointInventoryForceFreshScanRequest.MetadataEntry do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.EndpointInventoryForceFreshScanRequest.MetadataEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Monitoring.EndpointInventoryForceFreshScanRequest do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.EndpointInventoryForceFreshScanRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :schema, 1, type: :string
  field :authorized, 2, type: :bool
  field :sources, 3, repeated: true, type: :string
  field :query, 4, type: Monitoring.EndpointInventoryQueryRequest

  field :metadata, 5,
    repeated: true,
    type: Monitoring.EndpointInventoryForceFreshScanRequest.MetadataEntry,
    map: true
end

defmodule Monitoring.EndpointInventoryPackagePredicate do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.EndpointInventoryPackagePredicate",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :package_manager, 1, type: :string, json_name: "packageManager"
  field :name, 2, type: :string
  field :version, 3, type: :string
  field :architecture, 4, type: :string
  field :ecosystem, 5, type: :string
  field :purl, 6, type: :string
  field :purl_canonical, 7, type: :string, json_name: "purlCanonical"
  field :cpe, 8, type: :string
end

defmodule Monitoring.EndpointInventoryStandingQuestionResultCount.LabelsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.EndpointInventoryStandingQuestionResultCount.LabelsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Monitoring.EndpointInventoryStandingQuestionResultCount.MetadataEntry do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.EndpointInventoryStandingQuestionResultCount.MetadataEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Monitoring.EndpointInventoryStandingQuestionResultCount do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.EndpointInventoryStandingQuestionResultCount",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :schema, 1, type: :string
  field :question_id, 2, type: :string, json_name: "questionId"
  field :question_version, 3, type: :string, json_name: "questionVersion"
  field :predicate_hash, 4, type: :string, json_name: "predicateHash"
  field :mode, 5, type: :string
  field :matched, 6, type: :bool
  field :count, 7, type: :int32
  field :package_set_hash, 8, type: :string, json_name: "packageSetHash"
  field :hash_algorithm, 9, type: :string, json_name: "hashAlgorithm"
  field :evaluated_at_unix, 10, type: :int64, json_name: "evaluatedAtUnix"
  field :freshness, 11, type: Monitoring.EndpointInventoryFreshness

  field :labels, 12,
    repeated: true,
    type: Monitoring.EndpointInventoryStandingQuestionResultCount.LabelsEntry,
    map: true

  field :metadata, 13,
    repeated: true,
    type: Monitoring.EndpointInventoryStandingQuestionResultCount.MetadataEntry,
    map: true
end

defmodule Monitoring.EndpointInventoryQueryResult do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.EndpointInventoryQueryResult",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :schema, 1, type: :string
  field :agent_id, 2, type: :string, json_name: "agentId"
  field :device_uid, 3, type: :string, json_name: "deviceUid"
  field :mode, 4, type: :string
  field :matched, 5, type: :bool
  field :count, 6, type: :int32
  field :packages, 7, repeated: true, type: Monitoring.EndpointInventoryPackageSummary
  field :package_set_hash, 8, type: :string, json_name: "packageSetHash"
  field :artifact_hash, 9, type: :string, json_name: "artifactHash"
  field :hash_algorithm, 10, type: :string, json_name: "hashAlgorithm"
  field :last_successful_scan_at_unix, 11, type: :int64, json_name: "lastSuccessfulScanAtUnix"
  field :last_changed_scan_at_unix, 12, type: :int64, json_name: "lastChangedScanAtUnix"
  field :unchanged_scan_count, 13, type: :int32, json_name: "unchangedScanCount"

  field :source_summaries, 14,
    repeated: true,
    type: Monitoring.EndpointInventorySourceSummary,
    json_name: "sourceSummaries"

  field :freshness, 15, type: Monitoring.EndpointInventoryFreshness
  field :stale_threshold_seconds, 16, type: :int64, json_name: "staleThresholdSeconds"
  field :evaluated_at_unix, 17, type: :int64, json_name: "evaluatedAtUnix"
  field :truncated, 18, type: :bool

  field :unsupported_capabilities, 19,
    repeated: true,
    type: :string,
    json_name: "unsupportedCapabilities"

  field :cohort_coverage, 20,
    type: Monitoring.EndpointInventoryCohortCoverage,
    json_name: "cohortCoverage"
end

defmodule Monitoring.SysmonConfig.ThresholdsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.SysmonConfig.ThresholdsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Monitoring.SysmonConfig do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.SysmonConfig",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :enabled, 1, type: :bool
  field :sample_interval, 2, type: :string, json_name: "sampleInterval"
  field :collect_cpu, 3, type: :bool, json_name: "collectCpu"
  field :collect_memory, 4, type: :bool, json_name: "collectMemory"
  field :collect_disk, 5, type: :bool, json_name: "collectDisk"
  field :collect_network, 6, type: :bool, json_name: "collectNetwork"
  field :collect_processes, 7, type: :bool, json_name: "collectProcesses"
  field :disk_paths, 8, repeated: true, type: :string, json_name: "diskPaths"
  field :disk_exclude_paths, 14, repeated: true, type: :string, json_name: "diskExcludePaths"
  field :thresholds, 10, repeated: true, type: Monitoring.SysmonConfig.ThresholdsEntry, map: true
  field :profile_id, 11, type: :string, json_name: "profileId"
  field :profile_name, 12, type: :string, json_name: "profileName"
  field :config_source, 13, type: :string, json_name: "configSource"
  field :process_limit, 15, type: :int32, json_name: "processLimit"
end

defmodule Monitoring.AgentCheckConfig.SettingsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.AgentCheckConfig.SettingsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Monitoring.AgentCheckConfig do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.AgentCheckConfig",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :check_id, 1, type: :string, json_name: "checkId"
  field :check_type, 2, type: :string, json_name: "checkType"
  field :name, 3, type: :string
  field :enabled, 4, type: :bool
  field :interval_sec, 5, type: :int32, json_name: "intervalSec"
  field :timeout_sec, 6, type: :int32, json_name: "timeoutSec"
  field :target, 7, type: :string
  field :port, 8, type: :int32
  field :path, 9, type: :string
  field :method, 10, type: :string
  field :settings, 11, repeated: true, type: Monitoring.AgentCheckConfig.SettingsEntry, map: true
end

defmodule Monitoring.SNMPConfig do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.SNMPConfig",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :enabled, 1, type: :bool
  field :profile_id, 2, type: :string, json_name: "profileId"
  field :profile_name, 3, type: :string, json_name: "profileName"
  field :targets, 4, repeated: true, type: Monitoring.SNMPTargetConfig
end

defmodule Monitoring.VisibilityConfig do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.VisibilityConfig",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :enabled, 1, type: :bool
  field :capture_interfaces, 2, repeated: true, type: :string, json_name: "captureInterfaces"

  field :binary_overrides, 3,
    type: Monitoring.VisibilityBinaryOverrides,
    json_name: "binaryOverrides"

  field :device_bindings, 4,
    repeated: true,
    type: Monitoring.VisibilityDeviceBinding,
    json_name: "deviceBindings"

  field :default_sample_interval_ms, 5, type: :uint32, json_name: "defaultSampleIntervalMs"
  field :dpi, 20, type: Monitoring.VisibilityDpiConfig
  field :flow_table_max_entries, 40, type: :uint32, json_name: "flowTableMaxEntries"
end

defmodule Monitoring.VisibilityBinaryOverrides do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.VisibilityBinaryOverrides",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :path, 1, type: :string
end

defmodule Monitoring.VisibilityDeviceBinding do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.VisibilityDeviceBinding",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :ip, 1, type: :string
  field :profile_id, 2, type: :string, json_name: "profileId"
  field :profile_name, 3, type: :string, json_name: "profileName"
  field :fingerprint, 4, type: Monitoring.VisibilityFingerprintConfig
  field :sample_interval_ms, 5, type: :uint32, json_name: "sampleIntervalMs"
  field :dpi, 6, type: Monitoring.VisibilityDpiConfig
end

defmodule Monitoring.VisibilityFingerprintConfig do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.VisibilityFingerprintConfig",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :tcp, 1, type: :bool
  field :tls, 2, type: :bool
  field :http, 3, type: :bool
end

defmodule Monitoring.VisibilityDpiConfig do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.VisibilityDpiConfig",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :enabled, 1, type: :bool
  field :protocols, 2, repeated: true, type: :string
end

defmodule Monitoring.SNMPTargetConfig do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.SNMPTargetConfig",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :id, 1, type: :string
  field :name, 2, type: :string
  field :host, 3, type: :string
  field :port, 4, type: :uint32
  field :version, 5, type: Monitoring.SNMPVersion, enum: true
  field :community, 6, type: :string
  field :v3_auth, 7, type: Monitoring.SNMPv3Auth, json_name: "v3Auth"
  field :poll_interval_seconds, 8, type: :uint32, json_name: "pollIntervalSeconds"
  field :timeout_seconds, 9, type: :uint32, json_name: "timeoutSeconds"
  field :retries, 10, type: :uint32
  field :oids, 11, repeated: true, type: Monitoring.SNMPOIDConfig
end

defmodule Monitoring.SNMPv3Auth do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.SNMPv3Auth",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :username, 1, type: :string

  field :security_level, 2,
    type: Monitoring.SNMPSecurityLevel,
    json_name: "securityLevel",
    enum: true

  field :auth_protocol, 3,
    type: Monitoring.SNMPAuthProtocol,
    json_name: "authProtocol",
    enum: true

  field :auth_password, 4, type: :string, json_name: "authPassword"

  field :priv_protocol, 5,
    type: Monitoring.SNMPPrivProtocol,
    json_name: "privProtocol",
    enum: true

  field :priv_password, 6, type: :string, json_name: "privPassword"
end

defmodule Monitoring.SNMPOIDConfig do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.SNMPOIDConfig",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :oid, 1, type: :string
  field :name, 2, type: :string
  field :data_type, 3, type: Monitoring.SNMPDataType, json_name: "dataType", enum: true
  field :scale, 4, type: :double
  field :delta, 5, type: :bool
  field :mode, 6, type: :string
  field :max_rows, 7, type: :int32, json_name: "maxRows"
  field :walk_timeout_seconds, 8, type: :uint32, json_name: "walkTimeoutSeconds"
end

defmodule Monitoring.MtrMplsLabel do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.MtrMplsLabel",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :label, 1, type: :int32
  field :exp, 2, type: :int32
  field :s, 3, type: :bool
  field :ttl, 4, type: :int32
end

defmodule Monitoring.MtrAsnInfo do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.MtrAsnInfo",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :asn, 1, type: :int32
  field :org, 2, type: :string
end

defmodule Monitoring.MtrHopResult do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.MtrHopResult",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :hop_number, 1, type: :int32, json_name: "hopNumber"
  field :addr, 2, type: :string
  field :hostname, 3, type: :string
  field :ecmp_addrs, 4, repeated: true, type: :string, json_name: "ecmpAddrs"
  field :asn, 5, type: Monitoring.MtrAsnInfo
  field :mpls_labels, 6, repeated: true, type: Monitoring.MtrMplsLabel, json_name: "mplsLabels"
  field :sent, 7, type: :int32
  field :received, 8, type: :int32
  field :loss_pct, 9, type: :double, json_name: "lossPct"
  field :last_us, 10, type: :int64, json_name: "lastUs"
  field :avg_us, 11, type: :int64, json_name: "avgUs"
  field :min_us, 12, type: :int64, json_name: "minUs"
  field :max_us, 13, type: :int64, json_name: "maxUs"
  field :stddev_us, 14, type: :int64, json_name: "stddevUs"
  field :jitter_us, 15, type: :int64, json_name: "jitterUs"
  field :jitter_worst_us, 16, type: :int64, json_name: "jitterWorstUs"
  field :jitter_interarrival_us, 17, type: :int64, json_name: "jitterInterarrivalUs"
end

defmodule Monitoring.MtrTraceResult do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.MtrTraceResult",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :target, 1, type: :string
  field :target_ip, 2, type: :string, json_name: "targetIp"
  field :target_reached, 3, type: :bool, json_name: "targetReached"
  field :total_hops, 4, type: :int32, json_name: "totalHops"
  field :protocol, 5, type: :string
  field :ip_version, 6, type: :int32, json_name: "ipVersion"
  field :packet_size, 7, type: :int32, json_name: "packetSize"
  field :hops, 8, repeated: true, type: Monitoring.MtrHopResult
  field :agent_id, 9, type: :string, json_name: "agentId"
  field :gateway_id, 10, type: :string, json_name: "gatewayId"
  field :timestamp, 11, type: :int64
end

defmodule Monitoring.MtrCheckResult do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.MtrCheckResult",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :check_id, 1, type: :string, json_name: "checkId"
  field :check_name, 2, type: :string, json_name: "checkName"
  field :target, 3, type: :string
  field :device_id, 4, type: :string, json_name: "deviceId"
  field :available, 5, type: :bool
  field :trace, 6, type: Monitoring.MtrTraceResult
  field :timestamp, 7, type: :int64
  field :error, 8, type: :string
end

defmodule Monitoring.AgentService.Service do
  @moduledoc false

  use GRPC.Service, name: "monitoring.AgentService", protoc_gen_elixir_version: "0.16.0"

  rpc(:GetStatus, Monitoring.StatusRequest, Monitoring.StatusResponse)

  rpc(:GetResults, Monitoring.ResultsRequest, Monitoring.ResultsResponse)

  rpc(:StreamResults, Monitoring.ResultsRequest, stream(Monitoring.ResultsChunk))
end

defmodule Monitoring.AgentService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Monitoring.AgentService.Service
end

defmodule Monitoring.AgentGatewayService.Service do
  @moduledoc false

  use GRPC.Service, name: "monitoring.AgentGatewayService", protoc_gen_elixir_version: "0.16.0"

  rpc(:Hello, Monitoring.AgentHelloRequest, Monitoring.AgentHelloResponse)

  rpc(:GetConfig, Monitoring.AgentConfigRequest, Monitoring.AgentConfigResponse)

  rpc(:StreamConfig, Monitoring.AgentConfigRequest, stream(Monitoring.AgentConfigChunk))

  rpc(:PushStatus, Monitoring.GatewayStatusRequest, Monitoring.GatewayStatusResponse)

  rpc(:StreamStatus, stream(Monitoring.GatewayStatusChunk), Monitoring.GatewayStatusResponse)

  rpc(
    :ControlStream,
    stream(Monitoring.ControlStreamRequest),
    stream(Monitoring.ControlStreamResponse)
  )

  rpc(
    :ResolveCredentialGrant,
    Monitoring.CredentialBrokerResolveRequest,
    Monitoring.CredentialBrokerResolveResponse
  )

  rpc(
    :ResolveAutomationLaunchEnvelope,
    Monitoring.AutomationLaunchEnvelopeResolveRequest,
    Monitoring.AutomationLaunchEnvelopeResolveResponse
  )
end

defmodule Monitoring.AgentGatewayService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Monitoring.AgentGatewayService.Service
end
