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
end

defmodule Monitoring.GatewayStatusResponse do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.GatewayStatusResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :received, 1, type: :bool
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
  field :plugin_config, 11, type: Monitoring.PluginConfig, json_name: "pluginConfig"
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

defmodule Monitoring.ConfigAck do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.ConfigAck",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :config_version, 1, type: :string, json_name: "configVersion"
  field :timestamp, 2, type: :int64
end

defmodule Monitoring.ControlStreamRequest do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.ControlStreamRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :payload, 0

  field :hello, 1, type: Monitoring.ControlStreamHello, oneof: 0
  field :command_ack, 2, type: Monitoring.CommandAck, json_name: "commandAck", oneof: 0

  field :command_progress, 3,
    type: Monitoring.CommandProgress,
    json_name: "commandProgress",
    oneof: 0

  field :command_result, 4, type: Monitoring.CommandResult, json_name: "commandResult", oneof: 0
  field :config_ack, 5, type: Monitoring.ConfigAck, json_name: "configAck", oneof: 0
end

defmodule Monitoring.ControlStreamResponse do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.ControlStreamResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :payload, 0

  field :command, 1, type: Monitoring.CommandRequest, oneof: 0
  field :config, 2, type: Monitoring.AgentConfigResponse, oneof: 0
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
end

defmodule Monitoring.AgentService.Service do
  @moduledoc false

  use GRPC.Service, name: "monitoring.AgentService", protoc_gen_elixir_version: "0.16.0"

  rpc :GetStatus, Monitoring.StatusRequest, Monitoring.StatusResponse

  rpc :GetResults, Monitoring.ResultsRequest, Monitoring.ResultsResponse

  rpc :StreamResults, Monitoring.ResultsRequest, stream(Monitoring.ResultsChunk)
end

defmodule Monitoring.AgentService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Monitoring.AgentService.Service
end

defmodule Monitoring.AgentGatewayService.Service do
  @moduledoc false

  use GRPC.Service, name: "monitoring.AgentGatewayService", protoc_gen_elixir_version: "0.16.0"

  rpc :Hello, Monitoring.AgentHelloRequest, Monitoring.AgentHelloResponse

  rpc :GetConfig, Monitoring.AgentConfigRequest, Monitoring.AgentConfigResponse

  rpc :PushStatus, Monitoring.GatewayStatusRequest, Monitoring.GatewayStatusResponse

  rpc :StreamStatus, stream(Monitoring.GatewayStatusChunk), Monitoring.GatewayStatusResponse

  rpc :ControlStream,
      stream(Monitoring.ControlStreamRequest),
      stream(Monitoring.ControlStreamResponse)
end

defmodule Monitoring.AgentGatewayService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Monitoring.AgentGatewayService.Service
end
