defmodule Core.GetCanonicalDeviceRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :identity_keys, 1,
    repeated: true,
    type: Identitymap.V1.IdentityKey,
    json_name: "identityKeys"

  field :namespace, 2, type: :string
  field :ip_hint, 3, type: :string, json_name: "ipHint"
end

defmodule Core.GetCanonicalDeviceResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :found, 1, type: :bool
  field :record, 2, type: Identitymap.V1.CanonicalRecord
  field :matched_key, 3, type: Identitymap.V1.IdentityKey, json_name: "matchedKey"
  field :revision, 4, type: :uint64
  field :hydrated, 5, type: :bool
end

defmodule Core.RegisterTemplateRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :service_name, 1, type: :string, json_name: "serviceName"
  field :template_data, 2, type: :bytes, json_name: "templateData"
  field :format, 3, type: :string
  field :service_version, 4, type: :string, json_name: "serviceVersion"
end

defmodule Core.RegisterTemplateResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :success, 1, type: :bool
  field :message, 2, type: :string
end

defmodule Core.GetTemplateRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :service_name, 1, type: :string, json_name: "serviceName"
end

defmodule Core.GetTemplateResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :found, 1, type: :bool
  field :template_data, 2, type: :bytes, json_name: "templateData"
  field :format, 3, type: :string
  field :service_version, 4, type: :string, json_name: "serviceVersion"
  field :registered_at, 5, type: :int64, json_name: "registeredAt"
end

defmodule Core.ListTemplatesRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :prefix, 1, type: :string
end

defmodule Core.ListTemplatesResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :templates, 1, repeated: true, type: Core.TemplateInfo
end

defmodule Core.TemplateInfo do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :service_name, 1, type: :string, json_name: "serviceName"
  field :format, 2, type: :string
  field :service_version, 3, type: :string, json_name: "serviceVersion"
  field :registered_at, 4, type: :int64, json_name: "registeredAt"
  field :size_bytes, 5, type: :int32, json_name: "sizeBytes"
end

defmodule Core.CoreService.Service do
  @moduledoc false

  use GRPC.Service, name: "core.CoreService", protoc_gen_elixir_version: "0.13.0"

  rpc(:GetCanonicalDevice, Core.GetCanonicalDeviceRequest, Core.GetCanonicalDeviceResponse)

  rpc(:RegisterTemplate, Core.RegisterTemplateRequest, Core.RegisterTemplateResponse)

  rpc(:GetTemplate, Core.GetTemplateRequest, Core.GetTemplateResponse)

  rpc(:ListTemplates, Core.ListTemplatesRequest, Core.ListTemplatesResponse)
end

defmodule Core.CoreService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Core.CoreService.Service
end
