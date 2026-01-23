defmodule Proto.NATSAccountService.Service do
  @moduledoc false

  use GRPC.Service, name: "proto.NATSAccountService", protoc_gen_elixir_version: "0.15.0"

  rpc(:BootstrapOperator, Proto.BootstrapOperatorRequest, Proto.BootstrapOperatorResponse)
  rpc(:GetOperatorInfo, Proto.GetOperatorInfoRequest, Proto.GetOperatorInfoResponse)
  rpc(:CreateAccount, Proto.CreateAccountRequest, Proto.CreateAccountResponse)

  rpc(
    :GenerateUserCredentials,
    Proto.GenerateUserCredentialsRequest,
    Proto.GenerateUserCredentialsResponse
  )

  rpc(:SignAccountJWT, Proto.SignAccountJWTRequest, Proto.SignAccountJWTResponse)
  rpc(:PushAccountJWT, Proto.PushAccountJWTRequest, Proto.PushAccountJWTResponse)
end

defmodule Proto.NATSAccountService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Proto.NATSAccountService.Service
end
