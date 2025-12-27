defmodule Proto.ObjectMetadata.AttributesEntry do
  @moduledoc false

  use Protobuf, map: true, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Proto.ObjectMetadata do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :key, 1, type: :string
  field :domain, 2, type: :string
  field :content_type, 3, type: :string, json_name: "contentType"
  field :compression, 4, type: :string
  field :sha256, 5, type: :string
  field :total_size, 6, type: :int64, json_name: "totalSize"
  field :attributes, 7, repeated: true, type: Proto.ObjectMetadata.AttributesEntry, map: true
end

defmodule Proto.ObjectUploadChunk do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :metadata, 1, type: Proto.ObjectMetadata
  field :data, 2, type: :bytes
  field :chunk_index, 3, type: :uint32, json_name: "chunkIndex"
  field :is_final, 4, type: :bool, json_name: "isFinal"
end

defmodule Proto.ObjectInfo do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :metadata, 1, type: Proto.ObjectMetadata
  field :sha256, 2, type: :string
  field :size, 3, type: :int64
  field :created_at_unix, 4, type: :int64, json_name: "createdAtUnix"
  field :modified_at_unix, 5, type: :int64, json_name: "modifiedAtUnix"
  field :chunks, 6, type: :uint64
end

defmodule Proto.UploadObjectResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :info, 1, type: Proto.ObjectInfo
end

defmodule Proto.DownloadObjectRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :key, 1, type: :string
end

defmodule Proto.ObjectDownloadChunk do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :info, 1, type: Proto.ObjectInfo
  field :data, 2, type: :bytes
  field :chunk_index, 3, type: :uint32, json_name: "chunkIndex"
  field :is_final, 4, type: :bool, json_name: "isFinal"
end

defmodule Proto.DeleteObjectRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :key, 1, type: :string
end

defmodule Proto.DeleteObjectResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :deleted, 1, type: :bool
end

defmodule Proto.GetObjectInfoRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :key, 1, type: :string
end

defmodule Proto.GetObjectInfoResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :info, 1, type: Proto.ObjectInfo
  field :found, 2, type: :bool
end

defmodule Proto.DataService.Service do
  @moduledoc false

  use GRPC.Service, name: "proto.DataService", protoc_gen_elixir_version: "0.13.0"

  rpc(:UploadObject, stream(Proto.ObjectUploadChunk), Proto.UploadObjectResponse)

  rpc(:DownloadObject, Proto.DownloadObjectRequest, stream(Proto.ObjectDownloadChunk))

  rpc(:DeleteObject, Proto.DeleteObjectRequest, Proto.DeleteObjectResponse)

  rpc(:GetObjectInfo, Proto.GetObjectInfoRequest, Proto.GetObjectInfoResponse)
end

defmodule Proto.DataService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Proto.DataService.Service
end
