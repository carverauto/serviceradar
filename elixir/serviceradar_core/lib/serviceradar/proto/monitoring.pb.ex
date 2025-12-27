defmodule Monitoring.SweepCompletionStatus.Status do
  @moduledoc false

  use Protobuf, enum: true, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :UNKNOWN, 0
  field :NOT_STARTED, 1
  field :IN_PROGRESS, 2
  field :COMPLETED, 3
  field :FAILED, 4
end

defmodule Monitoring.DeviceStatusRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :agent_id, 1, type: :string, json_name: "agentId"
end

defmodule Monitoring.StatusRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :service_name, 1, type: :string, json_name: "serviceName"
  field :service_type, 2, type: :string, json_name: "serviceType"
  field :agent_id, 3, type: :string, json_name: "agentId"
  field :poller_id, 4, type: :string, json_name: "pollerId"
  field :details, 5, type: :string
  field :port, 6, type: :int32
end

defmodule Monitoring.ResultsRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :service_name, 1, type: :string, json_name: "serviceName"
  field :service_type, 2, type: :string, json_name: "serviceType"
  field :agent_id, 3, type: :string, json_name: "agentId"
  field :poller_id, 4, type: :string, json_name: "pollerId"
  field :details, 5, type: :string
  field :last_sequence, 6, type: :string, json_name: "lastSequence"

  field :completion_status, 7,
    type: Monitoring.SweepCompletionStatus,
    json_name: "completionStatus"
end

defmodule Monitoring.StatusResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :available, 1, type: :bool
  field :message, 2, type: :bytes
  field :service_name, 3, type: :string, json_name: "serviceName"
  field :service_type, 4, type: :string, json_name: "serviceType"
  field :response_time, 5, type: :int64, json_name: "responseTime"
  field :agent_id, 6, type: :string, json_name: "agentId"
  field :poller_id, 7, type: :string, json_name: "pollerId"
end

defmodule Monitoring.ResultsResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :available, 1, type: :bool
  field :data, 2, type: :bytes
  field :service_name, 3, type: :string, json_name: "serviceName"
  field :service_type, 4, type: :string, json_name: "serviceType"
  field :response_time, 5, type: :int64, json_name: "responseTime"
  field :agent_id, 6, type: :string, json_name: "agentId"
  field :poller_id, 7, type: :string, json_name: "pollerId"
  field :timestamp, 8, type: :int64
  field :current_sequence, 9, type: :string, json_name: "currentSequence"
  field :has_new_data, 10, type: :bool, json_name: "hasNewData"

  field :sweep_completion, 11,
    type: Monitoring.SweepCompletionStatus,
    json_name: "sweepCompletion"
end

defmodule Monitoring.PollerStatusRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :services, 1, repeated: true, type: Monitoring.ServiceStatus
  field :poller_id, 2, type: :string, json_name: "pollerId"
  field :agent_id, 3, type: :string, json_name: "agentId"
  field :timestamp, 4, type: :int64
  field :partition, 5, type: :string
  field :source_ip, 6, type: :string, json_name: "sourceIp"
  field :kv_store_id, 7, type: :string, json_name: "kvStoreId"
end

defmodule Monitoring.PollerStatusResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :received, 1, type: :bool
end

defmodule Monitoring.ServiceStatus do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :service_name, 1, type: :string, json_name: "serviceName"
  field :available, 2, type: :bool
  field :message, 3, type: :bytes
  field :service_type, 4, type: :string, json_name: "serviceType"
  field :response_time, 5, type: :int64, json_name: "responseTime"
  field :agent_id, 6, type: :string, json_name: "agentId"
  field :poller_id, 7, type: :string, json_name: "pollerId"
  field :partition, 8, type: :string
  field :source, 9, type: :string
  field :kv_store_id, 10, type: :string, json_name: "kvStoreId"
end

defmodule Monitoring.SweepServiceStatus do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :network, 1, type: :string
  field :total_hosts, 2, type: :int32, json_name: "totalHosts"
  field :available_hosts, 3, type: :int32, json_name: "availableHosts"
  field :ports, 4, repeated: true, type: Monitoring.PortStatus
  field :last_sweep, 5, type: :int64, json_name: "lastSweep"
end

defmodule Monitoring.PortStatus do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :port, 1, type: :int32
  field :available, 2, type: :int32
end

defmodule Monitoring.ResultsChunk do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :data, 1, type: :bytes
  field :is_final, 2, type: :bool, json_name: "isFinal"
  field :chunk_index, 3, type: :int32, json_name: "chunkIndex"
  field :total_chunks, 4, type: :int32, json_name: "totalChunks"
  field :current_sequence, 5, type: :string, json_name: "currentSequence"
  field :timestamp, 6, type: :int64
end

defmodule Monitoring.SweepCompletionStatus do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :status, 1, type: Monitoring.SweepCompletionStatus.Status, enum: true
  field :completion_time, 2, type: :int64, json_name: "completionTime"
  field :target_sequence, 3, type: :string, json_name: "targetSequence"
  field :total_targets, 4, type: :int32, json_name: "totalTargets"
  field :completed_targets, 5, type: :int32, json_name: "completedTargets"
  field :error_message, 6, type: :string, json_name: "errorMessage"
end

defmodule Monitoring.PollerStatusChunk do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :services, 1, repeated: true, type: Monitoring.ServiceStatus
  field :poller_id, 2, type: :string, json_name: "pollerId"
  field :agent_id, 3, type: :string, json_name: "agentId"
  field :timestamp, 4, type: :int64
  field :partition, 5, type: :string
  field :source_ip, 6, type: :string, json_name: "sourceIp"
  field :is_final, 7, type: :bool, json_name: "isFinal"
  field :chunk_index, 8, type: :int32, json_name: "chunkIndex"
  field :total_chunks, 9, type: :int32, json_name: "totalChunks"
  field :kv_store_id, 10, type: :string, json_name: "kvStoreId"
end

defmodule Monitoring.AgentService.Service do
  @moduledoc false

  use GRPC.Service, name: "monitoring.AgentService", protoc_gen_elixir_version: "0.13.0"

  rpc(:GetStatus, Monitoring.StatusRequest, Monitoring.StatusResponse)

  rpc(:GetResults, Monitoring.ResultsRequest, Monitoring.ResultsResponse)

  rpc(:StreamResults, Monitoring.ResultsRequest, stream(Monitoring.ResultsChunk))
end

defmodule Monitoring.AgentService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Monitoring.AgentService.Service
end

defmodule Monitoring.PollerService.Service do
  @moduledoc false

  use GRPC.Service, name: "monitoring.PollerService", protoc_gen_elixir_version: "0.13.0"

  rpc(:ReportStatus, Monitoring.PollerStatusRequest, Monitoring.PollerStatusResponse)

  rpc(:StreamStatus, stream(Monitoring.PollerStatusChunk), Monitoring.PollerStatusResponse)
end

defmodule Monitoring.PollerService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Monitoring.PollerService.Service
end
