defmodule Serviceradar.Edge.V1.K8sPublicEndpointsSnapshotV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.K8sPublicEndpointsSnapshotV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :schema_version, 1, type: :string, json_name: "schemaVersion"
  field :agent_id, 2, type: :string, json_name: "agentId"
  field :cluster_id, 3, type: :string, json_name: "clusterId"
  field :generated_at, 4, type: :string, json_name: "generatedAt"
  field :content_hash, 5, type: :string, json_name: "contentHash"
  field :endpoints, 6, repeated: true, type: Serviceradar.Edge.V1.K8sPublicEndpointV1

  field :correlation_hints, 7,
    repeated: true,
    type: Serviceradar.Edge.V1.K8sCorrelationHintV1,
    json_name: "correlationHints"
end

defmodule Serviceradar.Edge.V1.K8sPublicEndpointV1.AnnotationsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.K8sPublicEndpointV1.AnnotationsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Edge.V1.K8sPublicEndpointV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.K8sPublicEndpointV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :cluster_id, 1, type: :string, json_name: "clusterId"
  field :ip, 2, type: :string
  field :hostname, 3, type: :string
  field :port, 4, type: :int32
  field :protocol, 5, type: :string
  field :exposure_class, 6, type: :string, json_name: "exposureClass"
  field :external_traffic_policy, 7, type: :string, json_name: "externalTrafficPolicy"
  field :metallb_pool, 8, type: :string, json_name: "metallbPool"
  field :load_balancer_ip_mode, 9, type: :string, json_name: "loadBalancerIpMode"
  field :namespace, 10, type: :string
  field :service_name, 11, type: :string, json_name: "serviceName"
  field :service_uid, 12, type: :string, json_name: "serviceUid"
  field :gateway_name, 13, type: :string, json_name: "gatewayName"
  field :gateway_class, 14, type: :string, json_name: "gatewayClass"
  field :listener_name, 15, type: :string, json_name: "listenerName"
  field :route_kind, 16, type: :string, json_name: "routeKind"
  field :route_name, 17, type: :string, json_name: "routeName"

  field :backend_refs, 18,
    repeated: true,
    type: Serviceradar.Edge.V1.K8sBackendRefV1,
    json_name: "backendRefs"

  field :endpoint_targets, 19,
    repeated: true,
    type: Serviceradar.Edge.V1.K8sEndpointTargetV1,
    json_name: "endpointTargets"

  field :service_target_port, 20, type: :int32, json_name: "serviceTargetPort"
  field :service_target_name, 21, type: :string, json_name: "serviceTargetName"

  field :annotations, 22,
    repeated: true,
    type: Serviceradar.Edge.V1.K8sPublicEndpointV1.AnnotationsEntry,
    map: true

  field :observed_at, 23, type: :string, json_name: "observedAt"
end

defmodule Serviceradar.Edge.V1.K8sBackendRefV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.K8sBackendRefV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :group, 1, type: :string
  field :kind, 2, type: :string
  field :namespace, 3, type: :string
  field :name, 4, type: :string
  field :port, 5, type: :int32
  field :weight, 6, type: :int32
end

defmodule Serviceradar.Edge.V1.K8sEndpointTargetV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.K8sEndpointTargetV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :ip, 1, type: :string
  field :port, 2, type: :int32
  field :protocol, 3, type: :string
  field :pod_namespace, 4, type: :string, json_name: "podNamespace"
  field :pod_name, 5, type: :string, json_name: "podName"
  field :node_name, 6, type: :string, json_name: "nodeName"
  field :ready, 7, type: :bool
end

defmodule Serviceradar.Edge.V1.K8sCorrelationHintV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.K8sCorrelationHintV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :public_ip, 1, type: :string, json_name: "publicIp"
  field :public_hostname, 2, type: :string, json_name: "publicHostname"
  field :public_port, 3, type: :int32, json_name: "publicPort"
  field :protocol, 4, type: :string
  field :backend_ip, 5, type: :string, json_name: "backendIp"
  field :backend_port, 6, type: :int32, json_name: "backendPort"
  field :pod_namespace, 7, type: :string, json_name: "podNamespace"
  field :pod_name, 8, type: :string, json_name: "podName"
  field :node_name, 9, type: :string, json_name: "nodeName"
  field :namespace, 10, type: :string
  field :service_name, 11, type: :string, json_name: "serviceName"
  field :gateway_name, 12, type: :string, json_name: "gatewayName"
  field :route_kind, 13, type: :string, json_name: "routeKind"
  field :route_name, 14, type: :string, json_name: "routeName"
  field :exposure_class, 15, type: :string, json_name: "exposureClass"
end
