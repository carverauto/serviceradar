defmodule Netprobepb.FlowAttributionEvent do
  @moduledoc """
  Runtime decoder for the netprobe v1 `FlowAttributionEvent` payload.

  This module mirrors the proto schema at
  `proto/agent/netprobe/v1/netprobe.proto:270-290` so that core-elx can
  decode the per-event records carried inside a
  `Netprobepb.FlowAttributionEventBatch` without requiring a regeneration of
  the netprobe protobuf stubs. Field numbers/types must stay in sync with the
  source proto.
  """

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :local_ip, 1, type: :string, json_name: "localIp"
  field :local_port, 2, type: :uint32, json_name: "localPort"
  field :remote_ip, 3, type: :string, json_name: "remoteIp"
  field :remote_port, 4, type: :uint32, json_name: "remotePort"
  field :transport_protocol, 5, type: :string, json_name: "transportProtocol"
  field :pid, 6, type: :uint32
  field :tgid, 7, type: :uint32
  field :uid, 8, type: :uint32
  field :gid, 9, type: :uint32
  field :comm, 10, type: :string
  field :redacted_cmdline, 11, repeated: true, type: :string, json_name: "redactedCmdline"
  field :container_id, 12, type: :string, json_name: "containerId"
  field :observed_at_unix_nano, 13, type: :int64, json_name: "observedAtUnixNano"
  field :socket_address, 14, type: :uint64, json_name: "socketAddress"
  field :event_kind, 15, type: :uint32, json_name: "eventKind"
  field :old_state, 16, type: :int32, json_name: "oldState"
  field :new_state, 17, type: :int32, json_name: "newState"
  field :source, 18, type: :string
  field :external_flow_id, 19, type: :uint64, json_name: "externalFlowId"
end

defmodule Netprobepb.FlowAttributionEventBatch do
  @moduledoc """
  Runtime decoder for the netprobe v1 `FlowAttributionEventBatch` payload.

  Carried inside `Monitoring.GatewayServiceStatus.message` when
  `source == "flow-attribution"`. Field numbers/types must stay in sync with
  `proto/agent/netprobe/v1/netprobe.proto:307-312`.
  """

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :events, 1, repeated: true, type: Netprobepb.FlowAttributionEvent
  field :batch_start_unix_nano, 2, type: :int64, json_name: "batchStartUnixNano"
  field :batch_end_unix_nano, 3, type: :int64, json_name: "batchEndUnixNano"
  field :dropped_since_last, 4, type: :uint32, json_name: "droppedSinceLast"
end
