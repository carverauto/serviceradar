defmodule Identitymap.V1.IdentityKind do
  @moduledoc false

  use Protobuf, enum: true, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :IDENTITY_KIND_UNSPECIFIED, 0
  field :IDENTITY_KIND_DEVICE_ID, 1
  field :IDENTITY_KIND_ARMIS_ID, 2
  field :IDENTITY_KIND_NETBOX_ID, 3
  field :IDENTITY_KIND_MAC, 4
  field :IDENTITY_KIND_IP, 5
  field :IDENTITY_KIND_PARTITION_IP, 6
end

defmodule Identitymap.V1.IdentityKey do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :kind, 1, type: Identitymap.V1.IdentityKind, enum: true
  field :value, 2, type: :string
end

defmodule Identitymap.V1.Attribute do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Identitymap.V1.CanonicalRecord do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :canonical_device_id, 1, type: :string, json_name: "canonicalDeviceId"
  field :partition, 2, type: :string
  field :metadata_hash, 3, type: :string, json_name: "metadataHash"
  field :updated_at_unix_millis, 4, type: :int64, json_name: "updatedAtUnixMillis"
  field :attributes, 5, repeated: true, type: Identitymap.V1.Attribute
end
