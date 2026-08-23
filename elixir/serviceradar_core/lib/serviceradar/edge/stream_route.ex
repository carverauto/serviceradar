defmodule ServiceRadar.Edge.StreamRoute do
  @moduledoc """
  The installation-local JetStream route map shared by the gateway publisher and the
  EventWriter/Broadway consumers (unify-sweep-results-proto task 4.1).

  Routing is deterministic and derivable from the verified contract alone -- no broker-account
  prefix, no cross-account mirror -- so a publisher and a consumer independently compute the same
  subject for the same record. This module holds no NATS I/O.

  ## The normative subject topology

  These five families are the whole space, fixed by the `nats-tenant-isolation` spec:

      telemetry.edge-record.v1.bulk.pNN
      telemetry.edge-record.v1.interactive.pNN
      telemetry.edge-record-recovery.v1
      telemetry.edge-record-dlq.v1.bulk.pNN
      telemetry.edge-record-dlq.v1.interactive.pNN

  Three consequences that are easy to get wrong, and were:

    * **The data subject keys on TRAFFIC CLASS, not route profile.** The route profile selects
      which FAMILY applies (durable-record vs recovery); it never appears as a subject token.
    * **Recovery is one singular reserved lane.** No class token, no partition token, and its own
      unborrowable storage/PubAck/consumer capacity.
    * **There is no recovery DLQ family.** A recovery failure preserves its ORIGINAL traffic
      class and enters the ordinary class-separated DLQ. That is why `resolve_dlq/2` takes a
      traffic class and NOT a route profile -- collapsing recovery's DLQ the way its data lane
      collapses would merge bulk and interactive poison into one queue, and the spec requires the
      DLQ to preserve class precisely so a bulk poison cohort cannot queue ahead of the
      interactive reserve.

  ## Partition-to-stream placement is currently uniform, and the spec allows more

  The normative map assigns every `(route profile, traffic class, logical partition)` to exactly
  one authoritative physical stream, and it explicitly MAY place disjoint partitions on
  additional stream/RAFT groups when benchmarked write, storage, or recovery limits require it.

  This installation maps ALL partitions of a class to one stream, which is a valid instance of
  that map but not the general case. `ResolvedRoute` carries the partition and the expected stream
  together precisely so the general case is a change here rather than at every call site: nothing
  downstream infers the stream from the class. Splitting a partition range onto its own stream is
  a placement change and therefore a `map_version/0` bump, with the sealing/revocation dance the
  spec requires.

  ## The active route map is NOT the enum

  `EdgeRecordRouteProfile` declares `CONTINUOUS_V1`, but declaring a member in the frozen ABI
  does not deploy it: the proto says another profile "requires an explicit benchmarked platform
  change", and no such change has happened. So `CONTINUOUS_V1` is UNROUTABLE here, and enum
  membership must never be the thing that decides. Deriving the active map from the enum would
  activate a route the platform has not provisioned the moment someone adds a member -- publishes
  would resolve to a stream that does not exist.

  Activating it later means adding its subject family to the spec, provisioning the streams, and
  bumping `map_version/0`.

  ## Elixir only

  A Go `streamroute` exists on the abandoned `usp-2x` branches. It is not the source of truth and
  must not be revived: the agent-gateway has been Elixir for over a year and the consumers are
  Elixir (EventWriter / core-elx / Broadway). The only Go left on this path is
  `serviceradar-agent`, which sends frames over gRPC and never computes a subject. With no second
  implementation there is nothing to drift from, which is why this map needs no cross-language
  vector file -- unlike the publication-identity grammar, which has one because both languages
  compute it.
  """

  alias ServiceRadar.Edge.ResolvedRoute

  @num_partitions 64

  # The ACTIVE route-map generation. It versions the subject topology AND the physical-stream
  # mapping together, and it is what the transport provenance records. It is not caller-supplied:
  # a record stamped with a generation other than the one that produced its subject describes a
  # placement that never happened.
  @map_version 1

  @durable_records :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1
  @recovery_control :EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1

  @bulk :EDGE_RECORD_TRAFFIC_CLASS_BULK
  @interactive :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE

  @class_tokens %{@bulk => "bulk", @interactive => "interactive"}

  @recovery_subject "telemetry.edge-record-recovery.v1"

  # Physical stream names are NOT specified normatively -- the spec fixes the subject families and
  # requires the streams behind them to be disjoint, leaving the names to the installation. They
  # are derived mechanically from the subject family so the correspondence stays obvious, and the
  # five are disjoint as required, with recovery holding its own.
  @recovery_stream "TELEMETRY_EDGE_RECORD_RECOVERY_V1"

  @doc "The fixed count of stable logical data/DLQ partitions."
  def num_partitions, do: @num_partitions

  @doc "The active route-map generation, versioning subjects and physical streams together."
  def map_version, do: @map_version

  @doc """
  Every DEPLOYMENT-ACTIVE `{route_profile, traffic_class}` pair, in a stable order.

  Derived from the active map rather than from the enum; see the moduledoc on `CONTINUOUS_V1`.
  """
  def active_lanes do
    [
      {@durable_records, @bulk},
      {@durable_records, @interactive},
      {@recovery_control, @bulk},
      {@recovery_control, @interactive}
    ]
  end

  @doc """
  Resolves the data route for a verified contract.

  `contract` is the GATEWAY-VERIFIED description of the record, never anything read out of the
  frame:

    * `:route_profile`, `:traffic_class` — from the effective control-plane grant.
    * `:network_scope_id` — the signed scope, used as the partition key for partitioned families.

  There is no caller-supplied partition key and no caller-supplied map version. Partition rules
  are CONTRACT-SPECIFIC -- the recovery family is unpartitioned entirely -- so letting a caller
  choose the key meant a caller could partition a record by something the contract does not
  partition by, and letting it default universally to network scope silently gave the recovery
  lane a partition it does not have.
  """
  @spec resolve(map()) :: {:ok, ResolvedRoute.t()} | {:error, atom()}
  def resolve(contract) when is_map(contract) do
    profile = Map.get(contract, :route_profile)
    class = Map.get(contract, :traffic_class)

    case {profile, valid_class(class)} do
      {@recovery_control, {:ok, _token}} ->
        # Singular and unpartitioned by contract: no class token, no pNN.
        {:ok, route(@recovery_subject, nil, @recovery_stream)}

      {@durable_records, {:ok, token}} ->
        with {:ok, partition} <- partition_for_scope(contract) do
          {:ok,
           route(
             "telemetry.edge-record.v1.#{token}.#{pad(partition)}",
             partition,
             "TELEMETRY_EDGE_RECORD_V1_#{String.upcase(token)}"
           )}
        end

      {_, {:error, reason}} ->
        {:error, reason}

      _ ->
        # Includes CONTINUOUS_V1: declared in the ABI, not deployment-active.
        {:error, :unroutable_lane}
    end
  end

  def resolve(_), do: {:error, :contract}

  @doc """
  Resolves the class-preserving DLQ route.

  Takes a TRAFFIC CLASS and not a route profile, deliberately. Every failure -- including a
  recovery-lane failure -- enters the DLQ for its original class, so there is no route profile to
  supply and no way to express a collapsed recovery DLQ.

  The partition is passed rather than re-derived so a failure lands on the DLQ partition matching
  the data partition it came from. A recovery record has no data partition; give it the partition
  its scope would have used, which `partition/1` computes.
  """
  @spec resolve_dlq(atom(), non_neg_integer()) :: {:ok, ResolvedRoute.t()} | {:error, atom()}
  def resolve_dlq(traffic_class, partition) do
    with {:ok, token} <- valid_class(traffic_class),
         :ok <- check_partition(partition) do
      {:ok,
       route(
         "telemetry.edge-record-dlq.v1.#{token}.#{pad(partition)}",
         partition,
         "TELEMETRY_EDGE_RECORD_DLQ_V1_#{String.upcase(token)}"
       )}
    end
  end

  @doc """
  Maps a routing key to a stable partition in `[0, num_partitions)`.

  FNV-1a is kept from the reviewed design rather than swapped for `:erlang.phash2/2`: the
  partition is a DATA-PLACEMENT decision, so changing the hash silently re-places every future
  record relative to the streams already holding data.
  """
  def partition(key) when is_binary(key) and key != "", do: rem(fnv1a_32(key), @num_partitions)
  def partition(_), do: {:error, :partition_key}

  defp partition_for_scope(contract) do
    case Map.get(contract, :network_scope_id) do
      scope when is_binary(scope) and scope != "" -> {:ok, partition(scope)}
      # A missing scope is refused rather than routed to partition 0. Zero is a real partition,
      # so defaulting to it would pile every unpopulated contract onto one shard.
      _ -> {:error, :partition_key}
    end
  end

  defp route(subject, partition, stream) do
    %ResolvedRoute{
      subject: subject,
      partition: partition,
      expected_stream: stream,
      map_version: @map_version
    }
  end

  defp valid_class(class) do
    case Map.fetch(@class_tokens, class) do
      {:ok, token} -> {:ok, token}
      :error -> {:error, :unroutable_lane}
    end
  end

  defp check_partition(p) when is_integer(p) and p >= 0 and p < @num_partitions, do: :ok
  defp check_partition(_), do: {:error, :partition_out_of_range}

  # Two digits is exact for 64 partitions; widening the space is a map_version bump, which is what
  # keeps this from silently truncating.
  defp pad(p), do: "p" <> String.pad_leading(Integer.to_string(p), 2, "0")

  @fnv_offset_basis 2_166_136_261
  @fnv_prime 16_777_619
  @u32 0xFFFFFFFF

  defp fnv1a_32(binary) do
    for <<byte <- binary>>, reduce: @fnv_offset_basis do
      hash -> Bitwise.band(Bitwise.bxor(hash, byte) * @fnv_prime, @u32)
    end
  end
end
