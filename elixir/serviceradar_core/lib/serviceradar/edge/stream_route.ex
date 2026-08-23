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

  The data subject keys on TRAFFIC CLASS; the route profile selects which FAMILY applies and
  never appears as a token. Recovery is one singular reserved lane -- no class token, no partition
  token -- with its own unborrowable storage/PubAck/consumer capacity.

  There is no recovery DLQ family. A recovery failure preserves its ORIGINAL traffic class and
  enters the ordinary class-separated DLQ, because neither initial routing nor redrive may promote
  or demote a record's class.

  ## Two versions, deliberately separate

    * `partition_scheme_version/0` versions WHICH SUBJECT a key maps to: the subject families, the
      partition function, and the partition count. Changing any of them re-places future records
      relative to the data already stored.
    * `placement_version/0` versions the `(profile, class, partition) -> physical stream`
      assignment. This is what the transport provenance records, and what gateway and consumer
      readiness compare.

  They were one value, which was wrong: moving a partition range onto a new physical stream is an
  operational change with a sealing/revocation dance, while changing the hash re-partitions the
  whole key space. Conflating them means one cannot be done without falsely claiming the other.

  ## Partitioning follows the CONTRACT's pinned rule

  The partition rule is bound into the immutable output-contract bundle, alongside contract
  ID/version, canonicalization, cost model, and projector configuration. It is therefore NOT a
  property of this module to choose: different contracts may partition by execution, agent/event,
  or assignment/run coordinates rather than by network scope.

  `resolve/1` requires the contract to name its rule and REFUSES an unknown one. Exactly one rule
  is frozen today (`:network_scope_v1`); the rest arrive with the contract registry that owns
  them. Refusing is deliberate: inventing a key composition here would freeze a byte layout the
  registry has not specified, and a wrong frozen layout is far more expensive to undo than a
  refusal. There is NO default -- defaulting to network scope is what silently gave every
  contract one rule.

  ## Partition-to-stream placement is currently uniform, and the spec allows more

  The normative map assigns every `(route profile, traffic class, logical partition)` to exactly
  one authoritative physical stream, and it explicitly MAY place disjoint partitions on additional
  stream/RAFT groups when benchmarked limits require it. This installation maps ALL partitions of
  a class to one stream -- a valid instance, not the general case. `ResolvedRoute` carries the
  partition and the stream together so the general case is a change here rather than at every call
  site.

  ## The active route map is NOT the enum

  `EdgeRecordRouteProfile` declares `CONTINUOUS_V1`, but declaring a member in the frozen ABI does
  not deploy it: another profile "requires an explicit benchmarked platform change". Deriving the
  active map from the enum would activate a route the platform has not provisioned the moment
  someone adds a member.

  ## Elixir only

  A Go `streamroute` exists on the abandoned `usp-2x` branches. It is not the source of truth and
  must not be revived: the agent-gateway has been Elixir for over a year and the consumers are
  Elixir (EventWriter / core-elx / Broadway). The only Go left on this path is
  `serviceradar-agent`, which sends frames over gRPC and never computes a subject.
  """

  alias ServiceRadar.Edge.ResolvedRoute

  @num_partitions 64

  # Versions WHICH SUBJECT a key maps to: subject families + partition function + partition count.
  # Frozen by testdata/partition vectors; changing any of the three must bump this.
  @partition_scheme_version 1

  # Versions the (profile, class, partition) -> physical stream assignment. Recorded in transport
  # provenance and compared by gateway/consumer readiness.
  @placement_version 1

  @durable_records :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1
  @recovery_control :EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1

  @bulk :EDGE_RECORD_TRAFFIC_CLASS_BULK
  @interactive :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE

  @class_tokens %{@bulk => "bulk", @interactive => "interactive"}

  @recovery_subject "telemetry.edge-record-recovery.v1"
  @recovery_stream "TELEMETRY_EDGE_RECORD_RECOVERY_V1"

  # The frozen partition rules. One today; the rest arrive with the contract registry.
  @partition_rules [:network_scope_v1]

  @doc "The fixed count of stable logical data/DLQ partitions."
  def num_partitions, do: @num_partitions

  @doc "Versions the subject families, the partition function, and the partition count."
  def partition_scheme_version, do: @partition_scheme_version

  @doc "Versions the physical-stream assignment; recorded in transport provenance."
  def placement_version, do: @placement_version

  @doc "The partition rules this installation can evaluate."
  def partition_rules, do: @partition_rules

  @doc "Every DEPLOYMENT-ACTIVE `{route_profile, traffic_class}` pair, in a stable order."
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
    * `:partition_rule` — the rule the output-contract bundle pins. REQUIRED; no default.
    * `:partition_coordinates` — the authenticated coordinates the rule reads, e.g.
      `%{network_scope_id: <<...>>}` for `:network_scope_v1`.

  Returns `{:error, :unknown_partition_rule}` for a rule this installation cannot evaluate, which
  is a refusal rather than a fallback: a record routed by the wrong rule lands on a partition its
  consumers do not read.
  """
  @spec resolve(map()) :: {:ok, ResolvedRoute.t()} | {:error, atom()}
  def resolve(contract) when is_map(contract) do
    profile = Map.get(contract, :route_profile)
    class = Map.get(contract, :traffic_class)

    case {profile, valid_class(class)} do
      {@recovery_control, {:ok, _token}} ->
        # Singular and unpartitioned by contract: no class token, no pNN. The partition rule is
        # not consulted, because there is no partition to compute.
        {:ok, route(@recovery_subject, nil, @recovery_stream)}

      {@durable_records, {:ok, token}} ->
        with {:ok, partition} <- partition_for(contract) do
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
  Resolves the class-preserving DLQ route for a record that already has a data route.

  Takes the SOURCE route and the same verified contract, not an independent class and partition.
  Accepting those separately let a caller reclassify a failed record from interactive to bulk, or
  move it to another partition -- either of which rewrites the provenance of a failure. Both are
  now derived from the authoritative source.

  A recovery record has no source partition (`nil`), so the DLQ partition comes from the
  authenticated agent/spool coordinates instead. That keeps a recovery failure on a stable
  partition rather than an arbitrary one, without inventing a data partition the recovery lane
  does not have.
  """
  @spec resolve_dlq(ResolvedRoute.t(), map()) :: {:ok, ResolvedRoute.t()} | {:error, atom()}
  def resolve_dlq(%ResolvedRoute{} = source, contract) when is_map(contract) do
    with {:ok, token} <- valid_class(Map.get(contract, :traffic_class)),
         {:ok, partition} <- dlq_partition(source, contract) do
      {:ok,
       route(
         "telemetry.edge-record-dlq.v1.#{token}.#{pad(partition)}",
         partition,
         "TELEMETRY_EDGE_RECORD_DLQ_V1_#{String.upcase(token)}"
       )}
    end
  end

  def resolve_dlq(_, _), do: {:error, :source_route}

  # The source's own partition when it has one; otherwise the recovery lane's authenticated
  # agent/spool coordinates.
  defp dlq_partition(%ResolvedRoute{partition: p}, _contract) when is_integer(p), do: {:ok, p}

  defp dlq_partition(%ResolvedRoute{partition: nil}, contract) do
    coords = Map.get(contract, :partition_coordinates, %{})
    agent = Map.get(coords, :authenticated_agent_id)
    spool = Map.get(coords, :spool_id)

    if is_binary(agent) and agent != "" and is_binary(spool) and spool != "" do
      {:ok, partition(agent <> spool)}
    else
      {:error, :partition_key}
    end
  end

  @doc """
  Maps a routing key to a stable partition in `[0, num_partitions)`.

  FNV-1a, frozen by the committed partition vectors together with `num_partitions/0`. The
  partition is a DATA-PLACEMENT decision, so changing the hash silently re-places every future
  record relative to the streams already holding data; the vectors are what make that change
  loud.
  """
  def partition(key) when is_binary(key) and key != "", do: rem(fnv1a_32(key), @num_partitions)

  # Evaluates the contract's pinned rule. No default, and no fallback for an unknown rule.
  defp partition_for(contract) do
    coords = Map.get(contract, :partition_coordinates, %{})

    case Map.get(contract, :partition_rule) do
      :network_scope_v1 ->
        case Map.get(coords, :network_scope_id) do
          scope when is_binary(scope) and scope != "" ->
            {:ok, partition(scope)}

          # Refused rather than routed to partition 0: zero is a real partition, so defaulting
          # would pile every unpopulated contract onto one shard.
          _ ->
            {:error, :partition_key}
        end

      nil ->
        {:error, :missing_partition_rule}

      _ ->
        {:error, :unknown_partition_rule}
    end
  end

  defp route(subject, partition, stream) do
    %ResolvedRoute{
      subject: subject,
      partition: partition,
      expected_stream: stream,
      placement_version: @placement_version,
      partition_scheme_version: @partition_scheme_version
    }
  end

  defp valid_class(class) do
    case Map.fetch(@class_tokens, class) do
      {:ok, token} -> {:ok, token}
      :error -> {:error, :unroutable_lane}
    end
  end

  # Two digits is exact for 64 partitions; widening the space bumps the partition scheme version.
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
