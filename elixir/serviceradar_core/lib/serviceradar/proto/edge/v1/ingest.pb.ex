defmodule Serviceradar.Edge.V1.EdgeResultClientMessage do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeResultClientMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :payload, 0

  field :lane_open, 1,
    type: Serviceradar.Edge.V1.EdgeResultLaneOpen,
    json_name: "laneOpen",
    oneof: 0

  field :frame, 2, type: Serviceradar.Edge.V1.EdgeResultFrame, oneof: 0
end

defmodule Serviceradar.Edge.V1.EdgeResultServerMessage do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeResultServerMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof :payload, 0

  field :lane_open_ack, 1,
    type: Serviceradar.Edge.V1.EdgeResultLaneOpenAck,
    json_name: "laneOpenAck",
    oneof: 0

  field :ack, 2, type: Serviceradar.Edge.V1.EdgeResultAck, oneof: 0
end

defmodule Serviceradar.Edge.V1.EdgeResultIngest.Service do
  @moduledoc false

  use GRPC.Service,
    name: "serviceradar.edge.v1.EdgeResultIngest",
    protoc_gen_elixir_version: "0.16.0"

  rpc :Stream,
      stream(Serviceradar.Edge.V1.EdgeResultClientMessage),
      stream(Serviceradar.Edge.V1.EdgeResultServerMessage)
end

defmodule Serviceradar.Edge.V1.EdgeResultIngest.Stub do
  @moduledoc false

  use GRPC.Stub, service: Serviceradar.Edge.V1.EdgeResultIngest.Service
end
