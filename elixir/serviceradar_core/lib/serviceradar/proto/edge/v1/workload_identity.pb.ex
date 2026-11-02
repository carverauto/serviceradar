defmodule Serviceradar.Edge.V1.WorkloadIdentitySnapshotV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.WorkloadIdentitySnapshotV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :observed_at_unix_nano, 1, type: :int64, json_name: "observedAtUnixNano"
  field :enabled, 2, type: :bool
  field :endpoint, 3, type: Serviceradar.Edge.V1.WorkloadIdentitySnapshotEndpointV1
  field :count, 4, type: :uint32

  field :identities, 5,
    repeated: true,
    type: Serviceradar.Edge.V1.WorkloadIdentityContainerLookupV1

  field :degradation_reason, 6, type: :string, json_name: "degradationReason"
  field :context_name, 7, type: :string, json_name: "contextName"
  field :cluster_id, 8, type: :string, json_name: "clusterId"
  field :cluster_name, 9, type: :string, json_name: "clusterName"
end

defmodule Serviceradar.Edge.V1.WorkloadIdentitySnapshotEndpointV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.WorkloadIdentitySnapshotEndpointV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :type, 1, type: :string
  field :path, 2, type: :string
  field :source, 3, type: :string
  field :config_file_path, 4, type: :string, json_name: "configFilePath"
end

defmodule Serviceradar.Edge.V1.WorkloadIdentityContainerLookupV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.WorkloadIdentityContainerLookupV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :container_id, 1, type: :string, json_name: "containerId"
  field :identity, 2, type: Serviceradar.Edge.V1.WorkloadIdentityRecordV1
end

defmodule Serviceradar.Edge.V1.WorkloadIdentityRecordV1.LabelsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.WorkloadIdentityRecordV1.LabelsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Edge.V1.WorkloadIdentityRecordV1.AnnotationsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.WorkloadIdentityRecordV1.AnnotationsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Edge.V1.WorkloadIdentityRecordV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.WorkloadIdentityRecordV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :pod_sandbox_id, 1, type: :string, json_name: "podSandboxId"
  field :pod_name, 2, type: :string, json_name: "podName"
  field :pod_namespace, 3, type: :string, json_name: "podNamespace"
  field :pod_uid, 4, type: :string, json_name: "podUid"
  field :container_id, 5, type: :string, json_name: "containerId"
  field :container_name, 6, type: :string, json_name: "containerName"
  field :image, 7, type: :string
  field :image_ref, 8, type: :string, json_name: "imageRef"
  field :runtime_pid, 9, type: :uint32, json_name: "runtimePid"
  field :has_runtime_pid, 10, type: :bool, json_name: "hasRuntimePid"
  field :cgroup_path, 11, type: :string, json_name: "cgroupPath"

  field :labels, 12,
    repeated: true,
    type: Serviceradar.Edge.V1.WorkloadIdentityRecordV1.LabelsEntry,
    map: true

  field :annotations, 13,
    repeated: true,
    type: Serviceradar.Edge.V1.WorkloadIdentityRecordV1.AnnotationsEntry,
    map: true

  field :runtime_source, 14, type: :string, json_name: "runtimeSource"
  field :confidence, 15, type: :string
  field :degradation_reason, 16, type: :string, json_name: "degradationReason"
end
