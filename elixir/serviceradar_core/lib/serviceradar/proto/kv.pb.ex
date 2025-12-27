defmodule Proto.GetRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :key, 1, type: :string
end

defmodule Proto.GetResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :value, 1, type: :bytes
  field :found, 2, type: :bool
  field :revision, 3, type: :uint64
end

defmodule Proto.BatchGetRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :keys, 1, repeated: true, type: :string
end

defmodule Proto.BatchGetEntry do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :key, 1, type: :string
  field :value, 2, type: :bytes
  field :found, 3, type: :bool
  field :revision, 4, type: :uint64
end

defmodule Proto.BatchGetResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :results, 1, repeated: true, type: Proto.BatchGetEntry
end

defmodule Proto.PutRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :key, 1, type: :string
  field :value, 2, type: :bytes
  field :ttl_seconds, 3, type: :int64, json_name: "ttlSeconds"
end

defmodule Proto.PutResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"
end

defmodule Proto.KeyValueEntry do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :key, 1, type: :string
  field :value, 2, type: :bytes
end

defmodule Proto.PutManyRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :entries, 1, repeated: true, type: Proto.KeyValueEntry
  field :ttl_seconds, 2, type: :int64, json_name: "ttlSeconds"
end

defmodule Proto.PutManyResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"
end

defmodule Proto.UpdateRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :key, 1, type: :string
  field :value, 2, type: :bytes
  field :revision, 3, type: :uint64
  field :ttl_seconds, 4, type: :int64, json_name: "ttlSeconds"
end

defmodule Proto.UpdateResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :revision, 1, type: :uint64
end

defmodule Proto.DeleteRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :key, 1, type: :string
end

defmodule Proto.DeleteResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"
end

defmodule Proto.WatchRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :key, 1, type: :string
end

defmodule Proto.WatchResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :value, 1, type: :bytes
end

defmodule Proto.InfoRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"
end

defmodule Proto.InfoResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :domain, 1, type: :string
  field :bucket, 2, type: :string
  field :object_bucket, 3, type: :string, json_name: "objectBucket"
end

defmodule Proto.ListKeysRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :prefix, 1, type: :string
end

defmodule Proto.ListKeysResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :keys, 1, repeated: true, type: :string
end

defmodule Proto.KVService.Service do
  @moduledoc false

  use GRPC.Service, name: "proto.KVService", protoc_gen_elixir_version: "0.13.0"

  rpc(:Get, Proto.GetRequest, Proto.GetResponse)

  rpc(:BatchGet, Proto.BatchGetRequest, Proto.BatchGetResponse)

  rpc(:Put, Proto.PutRequest, Proto.PutResponse)

  rpc(:PutIfAbsent, Proto.PutRequest, Proto.PutResponse)

  rpc(:PutMany, Proto.PutManyRequest, Proto.PutManyResponse)

  rpc(:Update, Proto.UpdateRequest, Proto.UpdateResponse)

  rpc(:Delete, Proto.DeleteRequest, Proto.DeleteResponse)

  rpc(:Watch, Proto.WatchRequest, stream(Proto.WatchResponse))

  rpc(:Info, Proto.InfoRequest, Proto.InfoResponse)

  rpc(:ListKeys, Proto.ListKeysRequest, Proto.ListKeysResponse)
end

defmodule Proto.KVService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Proto.KVService.Service
end
