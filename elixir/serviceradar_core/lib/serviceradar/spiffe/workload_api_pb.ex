defmodule ServiceRadar.SPIFFE.Workload.X509SVIDRequest do
  @moduledoc false
  use Protobuf, syntax: :proto3
end

defmodule ServiceRadar.SPIFFE.Workload.X509SVID do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field :spiffe_id, 1, type: :string
  field :x509_svid, 2, type: :bytes
  field :x509_svid_key, 3, type: :bytes
  field :bundle, 4, type: :bytes
  field :hint, 5, type: :string
end

defmodule ServiceRadar.SPIFFE.Workload.X509SVIDResponse.FederatedBundlesEntry do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :bytes
end

defmodule ServiceRadar.SPIFFE.Workload.X509SVIDResponse do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field :svids, 1, repeated: true, type: ServiceRadar.SPIFFE.Workload.X509SVID
  field :crl, 2, repeated: true, type: :bytes

  field :federated_bundles, 3,
    repeated: true,
    type: ServiceRadar.SPIFFE.Workload.X509SVIDResponse.FederatedBundlesEntry,
    map: true
end

defmodule ServiceRadar.SPIFFE.Workload.API.Service do
  @moduledoc false
  use GRPC.Service, name: "SpiffeWorkloadAPI"

  rpc(
    :FetchX509SVID,
    ServiceRadar.SPIFFE.Workload.X509SVIDRequest,
    stream(ServiceRadar.SPIFFE.Workload.X509SVIDResponse)
  )
end

defmodule ServiceRadar.SPIFFE.Workload.API.Stub do
  @moduledoc false
  use GRPC.Stub, service: ServiceRadar.SPIFFE.Workload.API.Service
end
