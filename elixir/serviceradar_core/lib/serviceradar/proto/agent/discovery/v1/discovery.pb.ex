defmodule Serviceradar.Agent.Discovery.V1.DiscoveryEnvelope do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.discovery.v1.DiscoveryEnvelope",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :schema, 1, type: :string
  field :producer_id, 2, type: :string, json_name: "producerId"
  field :observation_scope, 3, type: :string, json_name: "observationScope"
  field :snapshot_id, 4, type: :string, json_name: "snapshotId"
  field :part_index, 5, type: :uint32, json_name: "partIndex"
  field :part_count, 6, type: :uint32, json_name: "partCount"
  field :complete, 7, type: :bool
  field :generated_at_unix_nano, 8, type: :int64, json_name: "generatedAtUnixNano"
  field :dropped_since_last, 9, type: :uint64, json_name: "droppedSinceLast"
  field :payload, 10, type: :bytes
end
