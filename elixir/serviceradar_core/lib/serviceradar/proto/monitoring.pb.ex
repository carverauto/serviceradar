defmodule Monitoring.SweepCompletionStatus.Status do
  @moduledoc false

  use Protobuf, enum: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :UNKNOWN, 0
  field :NOT_STARTED, 1
  field :IN_PROGRESS, 2
  field :COMPLETED, 3
  field :FAILED, 4
end

defmodule Monitoring.DeviceStatusRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :agent_id, 1, type: :string, json_name: "agentId"
end

defmodule Monitoring.StatusRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :service_name, 1, type: :string, json_name: "serviceName"
  field :service_type, 2, type: :string, json_name: "serviceType"
  field :agent_id, 3, type: :string, json_name: "agentId"
  field :gateway_id, 4, type: :string, json_name: "gatewayId"
  field :details, 5, type: :string
  field :port, 6, type: :int32
end

defmodule Monitoring.ResultsRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

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

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

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

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

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
end

defmodule Monitoring.SweepServiceStatus do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :network, 1, type: :string
  field :total_hosts, 2, type: :int32, json_name: "totalHosts"
  field :available_hosts, 3, type: :int32, json_name: "availableHosts"
  field :ports, 4, repeated: true, type: Monitoring.PortStatus
  field :last_sweep, 5, type: :int64, json_name: "lastSweep"
end

defmodule Monitoring.PortStatus do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :port, 1, type: :int32
  field :available, 2, type: :int32
end

defmodule Monitoring.ResultsChunk do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :data, 1, type: :bytes
  field :is_final, 2, type: :bool, json_name: "isFinal"
  field :chunk_index, 3, type: :int32, json_name: "chunkIndex"
  field :total_chunks, 4, type: :int32, json_name: "totalChunks"
  field :current_sequence, 5, type: :string, json_name: "currentSequence"
  field :timestamp, 6, type: :int64
end

defmodule Monitoring.SweepCompletionStatus do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :status, 1, type: Monitoring.SweepCompletionStatus.Status, enum: true
  field :completion_time, 2, type: :int64, json_name: "completionTime"
  field :target_sequence, 3, type: :string, json_name: "targetSequence"
  field :total_targets, 4, type: :int32, json_name: "totalTargets"
  field :completed_targets, 5, type: :int32, json_name: "completedTargets"
  field :error_message, 6, type: :string, json_name: "errorMessage"
end

defmodule Monitoring.GatewayStatusRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :services, 1, repeated: true, type: Monitoring.GatewayServiceStatus
  field :gateway_id, 2, type: :string, json_name: "gatewayId"
  field :agent_id, 3, type: :string, json_name: "agentId"
  field :timestamp, 4, type: :int64
  field :partition, 5, type: :string
  field :source_ip, 6, type: :string, json_name: "sourceIp"
  field :kv_store_id, 7, type: :string, json_name: "kvStoreId"
  field :tenant_id, 8, type: :string, json_name: "tenantId"
  field :tenant_slug, 9, type: :string, json_name: "tenantSlug"
end

defmodule Monitoring.GatewayStatusResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :received, 1, type: :bool
end

defmodule Monitoring.GatewayStatusChunk do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

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
  field :tenant_id, 11, type: :string, json_name: "tenantId"
  field :tenant_slug, 12, type: :string, json_name: "tenantSlug"
end

defmodule Monitoring.GatewayServiceStatus do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

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
  field :tenant_id, 11, type: :string, json_name: "tenantId"
  field :tenant_slug, 12, type: :string, json_name: "tenantSlug"
end

defmodule Monitoring.AgentHelloRequest.LabelsEntry do
  @moduledoc false

  use Protobuf, map: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Monitoring.AgentHelloRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :agent_id, 1, type: :string, json_name: "agentId"
  field :version, 2, type: :string
  field :capabilities, 3, repeated: true, type: :string
  field :hostname, 4, type: :string
  field :os, 5, type: :string
  field :arch, 6, type: :string
  field :partition, 7, type: :string
  field :config_version, 8, type: :string, json_name: "configVersion"
  field :labels, 9, repeated: true, type: Monitoring.AgentHelloRequest.LabelsEntry, map: true
end

defmodule Monitoring.AgentHelloResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :accepted, 1, type: :bool
  field :agent_id, 2, type: :string, json_name: "agentId"
  field :message, 3, type: :string
  field :gateway_id, 4, type: :string, json_name: "gatewayId"
  field :server_time, 5, type: :int64, json_name: "serverTime"
  field :heartbeat_interval_sec, 6, type: :int32, json_name: "heartbeatIntervalSec"
  field :config_outdated, 7, type: :bool, json_name: "configOutdated"
  field :tenant_id, 8, type: :string, json_name: "tenantId"
  field :tenant_slug, 9, type: :string, json_name: "tenantSlug"
end

defmodule Monitoring.AgentConfigRequest do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :agent_id, 1, type: :string, json_name: "agentId"
  field :config_version, 2, type: :string, json_name: "configVersion"
end

defmodule Monitoring.AgentConfigResponse do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :not_modified, 1, type: :bool, json_name: "notModified"
  field :config_version, 2, type: :string, json_name: "configVersion"
  field :config_timestamp, 3, type: :int64, json_name: "configTimestamp"
  field :heartbeat_interval_sec, 4, type: :int32, json_name: "heartbeatIntervalSec"
  field :config_poll_interval_sec, 5, type: :int32, json_name: "configPollIntervalSec"
  field :checks, 6, repeated: true, type: Monitoring.AgentCheckConfig
  field :config_json, 7, type: :bytes, json_name: "configJson"
end

defmodule Monitoring.AgentCheckConfig.SettingsEntry do
  @moduledoc false

  use Protobuf, map: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Monitoring.AgentCheckConfig do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

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

defmodule Monitoring.AgentService.Service do
  @moduledoc false

  use GRPC.Service, name: "monitoring.AgentService", protoc_gen_elixir_version: "0.15.0"

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

  use GRPC.Service, name: "monitoring.AgentGatewayService", protoc_gen_elixir_version: "0.15.0"

  rpc :Hello, Monitoring.AgentHelloRequest, Monitoring.AgentHelloResponse

  rpc :GetConfig, Monitoring.AgentConfigRequest, Monitoring.AgentConfigResponse

  rpc :PushStatus, Monitoring.GatewayStatusRequest, Monitoring.GatewayStatusResponse

  rpc :StreamStatus, stream(Monitoring.GatewayStatusChunk), Monitoring.GatewayStatusResponse
end

defmodule Monitoring.AgentGatewayService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Monitoring.AgentGatewayService.Service
end
