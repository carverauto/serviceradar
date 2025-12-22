defmodule ServiceRadarWebNG.Datasvc.KV.Proto do
  @moduledoc """
  Protobuf message definitions for the KV service.

  These match the definitions in proto/kv.proto from datasvc.
  """

  use Protobuf, syntax: :proto3

  defmodule ListKeysRequest do
    @moduledoc false
    use Protobuf, syntax: :proto3

    field :prefix, 1, type: :string
  end

  defmodule ListKeysResponse do
    @moduledoc false
    use Protobuf, syntax: :proto3

    field :keys, 1, repeated: true, type: :string
  end

  defmodule GetRequest do
    @moduledoc false
    use Protobuf, syntax: :proto3

    field :key, 1, type: :string
  end

  defmodule GetResponse do
    @moduledoc false
    use Protobuf, syntax: :proto3

    field :value, 1, type: :bytes
    field :found, 2, type: :bool
    field :revision, 3, type: :uint64
  end

  defmodule InfoRequest do
    @moduledoc false
    use Protobuf, syntax: :proto3
  end

  defmodule InfoResponse do
    @moduledoc false
    use Protobuf, syntax: :proto3

    field :domain, 1, type: :string
    field :bucket, 2, type: :string
    field :object_bucket, 3, type: :string
  end
end

defmodule ServiceRadarWebNG.Datasvc.KV.Proto.Service do
  @moduledoc """
  gRPC service definition for the KV service.
  """

  use GRPC.Service, name: "proto.KVService", protoc_gen_elixir_version: "0.12.0"

  alias ServiceRadarWebNG.Datasvc.KV.Proto

  rpc(:ListKeys, Proto.ListKeysRequest, Proto.ListKeysResponse)
  rpc(:Get, Proto.GetRequest, Proto.GetResponse)
  rpc(:Info, Proto.InfoRequest, Proto.InfoResponse)
end

defmodule ServiceRadarWebNG.Datasvc.KV.Proto.Stub do
  @moduledoc """
  gRPC client stub for the KV service.
  """

  use GRPC.Stub, service: ServiceRadarWebNG.Datasvc.KV.Proto.Service
end
