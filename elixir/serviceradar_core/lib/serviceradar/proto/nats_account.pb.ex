defmodule Proto.AccountLimits do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :max_connections, 1, type: :int64, json_name: "maxConnections"
  field :max_subscriptions, 2, type: :int64, json_name: "maxSubscriptions"
  field :max_payload_bytes, 3, type: :int64, json_name: "maxPayloadBytes"
  field :max_data_bytes, 4, type: :int64, json_name: "maxDataBytes"
  field :max_exports, 5, type: :int64, json_name: "maxExports"
  field :max_imports, 6, type: :int64, json_name: "maxImports"
  field :allow_wildcard_exports, 7, type: :bool, json_name: "allowWildcardExports"
end

defmodule Proto.SubjectMapping do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :from, 1, type: :string
  field :to, 2, type: :string
end

defmodule Proto.CreateTenantAccountRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :tenant_slug, 1, type: :string, json_name: "tenantSlug"
  field :limits, 2, type: Proto.AccountLimits
  field :subject_mappings, 3, repeated: true, type: Proto.SubjectMapping, json_name: "subjectMappings"
end

defmodule Proto.CreateTenantAccountResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :account_public_key, 1, type: :string, json_name: "accountPublicKey"
  field :account_seed, 2, type: :string, json_name: "accountSeed"
  field :account_jwt, 3, type: :string, json_name: "accountJwt"
end

defmodule Proto.UserCredentialType do
  @moduledoc false

  use Protobuf, enum: true, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :USER_CREDENTIAL_TYPE_UNSPECIFIED, 0
  field :USER_CREDENTIAL_TYPE_COLLECTOR, 1
  field :USER_CREDENTIAL_TYPE_SERVICE, 2
  field :USER_CREDENTIAL_TYPE_ADMIN, 3
end

defmodule Proto.UserPermissions do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :publish_allow, 1, repeated: true, type: :string, json_name: "publishAllow"
  field :publish_deny, 2, repeated: true, type: :string, json_name: "publishDeny"
  field :subscribe_allow, 3, repeated: true, type: :string, json_name: "subscribeAllow"
  field :subscribe_deny, 4, repeated: true, type: :string, json_name: "subscribeDeny"
  field :allow_responses, 5, type: :bool, json_name: "allowResponses"
  field :max_responses, 6, type: :int32, json_name: "maxResponses"
end

defmodule Proto.GenerateUserCredentialsRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :tenant_slug, 1, type: :string, json_name: "tenantSlug"
  field :account_seed, 2, type: :string, json_name: "accountSeed"
  field :user_name, 3, type: :string, json_name: "userName"
  field :credential_type, 4, type: Proto.UserCredentialType, json_name: "credentialType", enum: true
  field :permissions, 5, type: Proto.UserPermissions
  field :expiration_seconds, 6, type: :int64, json_name: "expirationSeconds"
end

defmodule Proto.GenerateUserCredentialsResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :user_public_key, 1, type: :string, json_name: "userPublicKey"
  field :user_jwt, 2, type: :string, json_name: "userJwt"
  field :creds_file_content, 3, type: :string, json_name: "credsFileContent"
  field :expires_at_unix, 4, type: :int64, json_name: "expiresAtUnix"
end

defmodule Proto.SignAccountJWTRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :tenant_slug, 1, type: :string, json_name: "tenantSlug"
  field :account_seed, 2, type: :string, json_name: "accountSeed"
  field :limits, 3, type: Proto.AccountLimits
  field :subject_mappings, 4, repeated: true, type: Proto.SubjectMapping, json_name: "subjectMappings"
  field :revoked_user_keys, 5, repeated: true, type: :string, json_name: "revokedUserKeys"
end

defmodule Proto.SignAccountJWTResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :account_public_key, 1, type: :string, json_name: "accountPublicKey"
  field :account_jwt, 2, type: :string, json_name: "accountJwt"
end

defmodule Proto.BootstrapOperatorRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :operator_name, 1, type: :string, json_name: "operatorName"
  field :existing_operator_seed, 2, type: :string, json_name: "existingOperatorSeed"
  field :generate_system_account, 3, type: :bool, json_name: "generateSystemAccount"
end

defmodule Proto.BootstrapOperatorResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :operator_public_key, 1, type: :string, json_name: "operatorPublicKey"
  field :operator_seed, 2, type: :string, json_name: "operatorSeed"
  field :operator_jwt, 3, type: :string, json_name: "operatorJwt"
  field :system_account_public_key, 4, type: :string, json_name: "systemAccountPublicKey"
  field :system_account_seed, 5, type: :string, json_name: "systemAccountSeed"
  field :system_account_jwt, 6, type: :string, json_name: "systemAccountJwt"
end

defmodule Proto.GetOperatorInfoRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"
end

defmodule Proto.GetOperatorInfoResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :operator_public_key, 1, type: :string, json_name: "operatorPublicKey"
  field :operator_name, 2, type: :string, json_name: "operatorName"
  field :is_initialized, 3, type: :bool, json_name: "isInitialized"
  field :system_account_public_key, 4, type: :string, json_name: "systemAccountPublicKey"
end

defmodule Proto.PushAccountJWTRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :account_public_key, 1, type: :string, json_name: "accountPublicKey"
  field :account_jwt, 2, type: :string, json_name: "accountJwt"
end

defmodule Proto.PushAccountJWTResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :success, 1, type: :bool
  field :message, 2, type: :string
end

defmodule Proto.NATSAccountService.Service do
  @moduledoc false

  use GRPC.Service, name: "proto.NATSAccountService", protoc_gen_elixir_version: "0.13.0"

  rpc(:BootstrapOperator, Proto.BootstrapOperatorRequest, Proto.BootstrapOperatorResponse)
  rpc(:GetOperatorInfo, Proto.GetOperatorInfoRequest, Proto.GetOperatorInfoResponse)
  rpc(:CreateTenantAccount, Proto.CreateTenantAccountRequest, Proto.CreateTenantAccountResponse)
  rpc(:GenerateUserCredentials, Proto.GenerateUserCredentialsRequest, Proto.GenerateUserCredentialsResponse)
  rpc(:SignAccountJWT, Proto.SignAccountJWTRequest, Proto.SignAccountJWTResponse)
  rpc(:PushAccountJWT, Proto.PushAccountJWTRequest, Proto.PushAccountJWTResponse)
end

defmodule Proto.NATSAccountService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Proto.NATSAccountService.Service
end
