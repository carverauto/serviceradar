defmodule Serviceradar.Edge.V1.UnleasedSweepResultsBatchV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.UnleasedSweepResultsBatchV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :execution_id, 1, type: :bytes, json_name: "executionId"
  field :sweep_group_id, 2, type: :bytes, json_name: "sweepGroupId"
  field :config_version, 3, type: :string, json_name: "configVersion"
  field :network_cidr, 4, type: :string, json_name: "networkCidr"
  field :sequence, 5, type: :uint64
  field :batch_started_at_unix_nano, 6, type: :uint64, json_name: "batchStartedAtUnixNano"
  field :batch_completed_at_unix_nano, 7, type: :uint64, json_name: "batchCompletedAtUnixNano"
  field :last_sweep_unix_nano, 8, type: :uint64, json_name: "lastSweepUnixNano"
  field :observed_at_unix_nano, 22, type: :int64, json_name: "observedAtUnixNano"
  field :chunk_index, 9, type: :uint32, json_name: "chunkIndex"
  field :total_chunks, 10, type: :uint32, json_name: "totalChunks"
  field :is_final, 11, type: :bool, json_name: "isFinal"
  field :is_cancelled, 12, type: :bool, json_name: "isCancelled"
  field :expected_total_hosts, 13, type: :uint32, json_name: "expectedTotalHosts"
  field :available_hosts, 14, type: :uint32, json_name: "availableHosts"
  field :configured_mode_bits, 15, type: :uint32, json_name: "configuredModeBits"

  field :tested_checks, 16,
    repeated: true,
    type: Serviceradar.Edge.V1.SweepTestV1,
    json_name: "testedChecks"

  field :execution_source, 17,
    type: Serviceradar.Edge.V1.SweepExecutionSource,
    json_name: "executionSource",
    enum: true

  field :hosts, 18, repeated: true, type: Serviceradar.Edge.V1.SweepHostObservationV1

  field :port_counts, 19,
    repeated: true,
    type: Serviceradar.Edge.V1.UnleasedSweepPortCountV1,
    json_name: "portCounts"

  field :scanner_stats, 20,
    type: Serviceradar.Edge.V1.UnleasedSweepScannerStatsV1,
    json_name: "scannerStats"

  field :banner_grab_summary, 21,
    type: Serviceradar.Edge.V1.UnleasedSweepBannerGrabSummaryV1,
    json_name: "bannerGrabSummary"
end

defmodule Serviceradar.Edge.V1.UnleasedSweepPortCountV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.UnleasedSweepPortCountV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :port, 1, type: :uint32
  field :available, 2, type: :uint32
end

defmodule Serviceradar.Edge.V1.UnleasedSweepScannerStatsV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.UnleasedSweepScannerStatsV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :protocol, 1, type: :string
  field :address_family, 2, type: :string, json_name: "addressFamily"
  field :scanner_path, 3, type: :string, json_name: "scannerPath"
  field :packets_sent, 4, type: :uint64, json_name: "packetsSent"
  field :packets_recv, 5, type: :uint64, json_name: "packetsRecv"
  field :packets_dropped, 6, type: :uint64, json_name: "packetsDropped"
  field :ring_blocks_processed, 7, type: :uint64, json_name: "ringBlocksProcessed"
  field :ring_blocks_dropped, 8, type: :uint64, json_name: "ringBlocksDropped"
  field :retries_attempted, 9, type: :uint64, json_name: "retriesAttempted"
  field :retries_successful, 10, type: :uint64, json_name: "retriesSuccessful"
  field :retries_dropped, 11, type: :uint64, json_name: "retriesDropped"
  field :ports_allocated, 12, type: :uint64, json_name: "portsAllocated"
  field :ports_released, 13, type: :uint64, json_name: "portsReleased"
  field :port_exhaustion_count, 14, type: :uint64, json_name: "portExhaustionCount"
  field :rate_limit_deferrals, 15, type: :uint64, json_name: "rateLimitDeferrals"
  field :rate_limit_waits, 16, type: :uint64, json_name: "rateLimitWaits"
  field :source_port_waits, 17, type: :uint64, json_name: "sourcePortWaits"
  field :rate_limit_wait_time_ms, 18, type: :uint64, json_name: "rateLimitWaitTimeMs"
  field :source_port_wait_time_ms, 19, type: :uint64, json_name: "sourcePortWaitTimeMs"
  field :rx_drop_rate_percent, 20, type: :double, json_name: "rxDropRatePercent"
  field :dials_started, 21, type: :uint64, json_name: "dialsStarted"
  field :dials_succeeded, 22, type: :uint64, json_name: "dialsSucceeded"
  field :dial_timeouts, 23, type: :uint64, json_name: "dialTimeouts"
  field :dial_resets, 24, type: :uint64, json_name: "dialResets"
  field :dial_resource_errors, 25, type: :uint64, json_name: "dialResourceErrors"
  field :active_dials, 26, type: :uint64, json_name: "activeDials"
  field :max_active_dials, 27, type: :uint64, json_name: "maxActiveDials"
  field :queue_depth, 28, type: :uint64, json_name: "queueDepth"
  field :max_queue_depth, 29, type: :uint64, json_name: "maxQueueDepth"
end

defmodule Serviceradar.Edge.V1.UnleasedSweepBannerGrabSummaryV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.UnleasedSweepBannerGrabSummaryV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :candidates_total, 1, type: :uint64, json_name: "candidatesTotal"
  field :probes_total, 2, type: :uint64, json_name: "probesTotal"
  field :inflight, 3, type: :uint64
  field :queue_depth, 4, type: :uint64, json_name: "queueDepth"
  field :match_batches_total, 5, type: :uint64, json_name: "matchBatchesTotal"
  field :match_batch_bytes_total, 6, type: :uint64, json_name: "matchBatchBytesTotal"
  field :bytes_received_total, 7, type: :uint64, json_name: "bytesReceivedTotal"
  field :skipped_fresh_total, 8, type: :uint64, json_name: "skippedFreshTotal"
  field :skipped_backoff_total, 9, type: :uint64, json_name: "skippedBackoffTotal"
  field :matches_total, 10, type: :uint64, json_name: "matchesTotal"
  field :empty_response_total, 11, type: :uint64, json_name: "emptyResponseTotal"
  field :connection_reset_total, 12, type: :uint64, json_name: "connectionResetTotal"
  field :timeout_total, 13, type: :uint64, json_name: "timeoutTotal"
  field :errors_total, 14, type: :uint64, json_name: "errorsTotal"
end
