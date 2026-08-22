defmodule ServiceRadar.Edge.StreamRoute do
  @moduledoc """
  The installation-local JetStream routing map shared by the gateway publisher and the
  EventWriter/Broadway consumers (unify-sweep-results-proto task 4.1).

  It defines the fixed, versioned subject space over 64 stable logical partitions, a
  class-preserving DLQ subject per lane, and a complete, non-overlapping
  `(traffic_class, route_profile, pNN) -> physical stream` map. Bulk and interactive resolve to
  disjoint physical streams so they never share capacity. Routing is deterministic and derivable
  from trusted identity alone -- no broker-account prefix, no cross-account mirror -- so a
  publisher and a consumer independently compute the same subject for the same frame. This
  module holds no NATS I/O.

  ## Elixir, not Go

  A Go `streamroute` package exists on the abandoned `usp-2x` branches. It is NOT the source of
  truth and must not be revived: the agent-gateway has been Elixir for over a year, and the
  consumers are Elixir (EventWriter / core-elx / Broadway). The only remaining Go component on
  this path is `serviceradar-agent`, which sends frames over gRPC and never computes a subject.
  With no second implementation there is nothing to drift from, which is why this map needs no
  cross-language vector file -- unlike the publication-identity grammar, which has one because
  Go and Elixir both compute it.

  ## This is a RE-KEY, not a port

  The Go version keyed on `EdgeResultLaneKind`, a dead enum whose five members conflated the
  payload family (sweep vs MTR) with the traffic class (bulk vs interactive):

      sweep.bulk  sweep.interactive  mtr.bulk  mtr.interactive  recovery

  The frozen ABI separates those concerns, and task 4.1 keys the map on
  `(traffic_class, route_profile, pNN)`. Payload family is therefore NOT a routing dimension any
  more: a sweep record and an MTR record with the same route profile and traffic class share a
  physical stream, where previously they could not. That is a deliberate consequence of the new
  contract, not an oversight -- `EdgeRecordRouteProfile` is "a finite platform deployment value,
  never a package-defined semantic type", so routing follows the deployment's durability profile
  rather than what the payload happens to contain.

  The lane count is unchanged at five, so the stream budget is the same shape as before.

  ## The one judgment call: recovery ignores traffic class

  `RECOVERY_CONTROL_V1` collapses to a single `recovery` lane for both traffic classes. Two
  things point that way and neither is conclusive on its own, so it is flagged here rather than
  buried: the recovery lane validator (`ServiceRadar.Edge.RecoveryValidate`) pins payload family,
  route profile, and source-authorization kind but says NOTHING about traffic class; and task 4.1
  lists "bulk/interactive, result-recovery, and class-preserving result-DLQ subjects" -- naming
  recovery as its own category ALONGSIDE bulk/interactive rather than crossed with them. Splitting
  recovery by class later is a subject-space change and therefore a `@subject_version` bump.
  """

  @num_partitions 64

  # Baked into every subject so a scheme change is an explicit, coordinated bump rather than a
  # silent re-placement of live data.
  @subject_version 1

  # Installation-local root. No customer/account prefix -- ServiceRadar is single-deployment.
  @subject_root "sr.edge.v1"

  @recovery_profile :EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1

  # (route_profile, traffic_class) -> stable subject token. The token distinguishes both
  # dimensions, so the physical-stream token mirrors it and the five lanes stay disjoint.
  @tokens %{
    {:EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1, :EDGE_RECORD_TRAFFIC_CLASS_BULK} =>
      "records.bulk",
    {:EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1, :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE} =>
      "records.interactive",
    {:EDGE_RECORD_ROUTE_PROFILE_CONTINUOUS_V1, :EDGE_RECORD_TRAFFIC_CLASS_BULK} =>
      "continuous.bulk",
    {:EDGE_RECORD_ROUTE_PROFILE_CONTINUOUS_V1, :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE} =>
      "continuous.interactive"
  }

  # Stable order. Used by provisioning and by tests that assert the map is total and
  # non-overlapping; do not sort this at the call site.
  @routable [
    {:EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1, :EDGE_RECORD_TRAFFIC_CLASS_BULK},
    {:EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1, :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE},
    {:EDGE_RECORD_ROUTE_PROFILE_CONTINUOUS_V1, :EDGE_RECORD_TRAFFIC_CLASS_BULK},
    {:EDGE_RECORD_ROUTE_PROFILE_CONTINUOUS_V1, :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE},
    {@recovery_profile, :EDGE_RECORD_TRAFFIC_CLASS_BULK},
    {@recovery_profile, :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE}
  ]

  @doc "The fixed count of stable logical data/DLQ partitions."
  def num_partitions, do: @num_partitions

  @doc "The versioned subject-scheme revision baked into every subject and stream name."
  def subject_version, do: @subject_version

  @doc """
  Every routable `{route_profile, traffic_class}` pair, in a stable order.

  Both recovery pairs appear even though they resolve to one lane, because the caller's input is
  a pair and a total map must answer for every pair it accepts.
  """
  def routable_lanes, do: @routable

  @doc """
  Maps a routing key to a stable partition in `[0, num_partitions)`.

  The key is the signed `network_scope_id`, or the execution id when scope is absent. FNV-1a is
  kept from the reviewed Go design rather than swapped for `:erlang.phash2/2`: the partition is a
  DATA-PLACEMENT decision, so changing the hash silently re-places every future record relative to
  the existing streams. An empty key maps to partition 0 rather than erroring, so a frame is
  always routable.
  """
  def partition(key) when is_binary(key) do
    if key == "" do
      0
    else
      rem(fnv1a_32(key), @num_partitions)
    end
  end

  @doc """
  The primary data subject, e.g. `"sr.edge.v1.records.bulk.p07.v1"`.

  Returns `{:error, :unroutable_lane}` for an unspecified/unknown pair and
  `{:error, :partition_out_of_range}` for a partition outside the fixed space -- never a subject
  built from a value it could not place.
  """
  def data_subject(route_profile, traffic_class, partition) do
    with {:ok, token} <- token(route_profile, traffic_class),
         :ok <- check_partition(partition) do
      {:ok, "#{@subject_root}.#{token}.#{pad(partition)}.v#{@subject_version}"}
    end
  end

  @doc """
  The class-preserving dead-letter subject. A distinct namespace from the data subject, so poison
  never lands on the live data stream.
  """
  def dlq_subject(route_profile, traffic_class, partition) do
    with {:ok, token} <- token(route_profile, traffic_class),
         :ok <- check_partition(partition) do
      {:ok, "#{@subject_root}.dlq.#{token}.#{pad(partition)}.v#{@subject_version}"}
    end
  end

  @doc """
  The physical data-stream name, e.g. `"EDGE_RECORDS_BULK_V1"`. This is the value for
  `Nats-Expected-Stream`, which fences a publish against landing on the wrong stream.
  """
  def physical_stream(route_profile, traffic_class) do
    with {:ok, token} <- token(route_profile, traffic_class) do
      {:ok, "EDGE_#{stream_name(token)}_V#{@subject_version}"}
    end
  end

  @doc "The physical DLQ-stream name, distinct from the data stream."
  def physical_dlq_stream(route_profile, traffic_class) do
    with {:ok, token} <- token(route_profile, traffic_class) do
      {:ok, "EDGE_DLQ_#{stream_name(token)}_V#{@subject_version}"}
    end
  end

  @doc """
  The stable subject token for a lane, or `{:error, :unroutable_lane}`.

  Recovery is matched BEFORE the table so it collapses both traffic classes to one lane; see the
  moduledoc for why that is a judgment call rather than a derivation.
  """
  def token(@recovery_profile, traffic_class) do
    if traffic_class in [
         :EDGE_RECORD_TRAFFIC_CLASS_BULK,
         :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE
       ] do
      {:ok, "recovery"}
    else
      {:error, :unroutable_lane}
    end
  end

  def token(route_profile, traffic_class) do
    case Map.fetch(@tokens, {route_profile, traffic_class}) do
      {:ok, token} -> {:ok, token}
      :error -> {:error, :unroutable_lane}
    end
  end

  defp check_partition(p) when is_integer(p) and p >= 0 and p < @num_partitions, do: :ok
  defp check_partition(_), do: {:error, :partition_out_of_range}

  # Two digits is exact for 64 partitions; widening the space is a @subject_version bump, which
  # is what keeps this from silently truncating.
  defp pad(p), do: "p" <> String.pad_leading(Integer.to_string(p), 2, "0")

  # "records.bulk" -> "RECORDS_BULK"
  defp stream_name(token) do
    token |> String.upcase() |> String.replace(".", "_")
  end

  @fnv_offset_basis 2_166_136_261
  @fnv_prime 16_777_619
  @u32 0xFFFFFFFF

  defp fnv1a_32(binary) do
    for <<byte <- binary>>, reduce: @fnv_offset_basis do
      hash -> Bitwise.band(Bitwise.bxor(hash, byte) * @fnv_prime, @u32)
    end
  end
end
