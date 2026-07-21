defmodule ServiceRadarAgentGateway.EdgeRoute do
  @moduledoc """
  Installation-local JetStream routing map for the edge result relay
  (unify-sweep-results-proto task 4.1), the Elixir peer of the Go reference core
  `go/pkg/edge/streamroute`. It MUST stay byte-identical to that core: a gateway
  (here) and a Go consumer independently compute the same subject/stream/partition
  for the same frame, so the two implementations are pinned together by golden
  values in the tests.

  Lanes are the five delivery classes (`:sweep_bulk`, `:sweep_interactive`,
  `:mtr_bulk`, `:mtr_interactive`, `:recovery`) over 64 stable logical
  partitions, each with a class-preserving DLQ subject and a disjoint physical
  stream (bulk/interactive and sweep/MTR never share a stream).
  """

  import Bitwise

  @num_partitions 64
  @subject_version 1
  @root "sr.edge.v1"

  @fnv_offset 2_166_136_261
  @fnv_prime 16_777_619
  @u32_mask 0xFFFFFFFF

  @type lane :: :sweep_bulk | :sweep_interactive | :mtr_bulk | :mtr_interactive | :recovery

  @doc "The fixed partition count."
  @spec num_partitions() :: pos_integer()
  def num_partitions, do: @num_partitions

  @doc """
  Maps a routing key (the signed network_scope_id, or execution id when scope is
  absent) to a stable partition in `0..63` via FNV-1a-32. An empty key maps to 0.
  """
  @spec partition(binary()) :: non_neg_integer()
  def partition(<<>>), do: 0
  def partition(key) when is_binary(key), do: rem(fnv1a_32(key), @num_partitions)
  def partition(_), do: 0

  @doc """
  Derives the delivery lane from a frame's payload kind and traffic class.
  Spool-loss tombstones always route to `:recovery`. Accepts protobuf enum atoms
  or their integer values.
  """
  @spec lane_for(term(), term()) :: lane()
  def lane_for(payload_kind, traffic_class) do
    cond do
      tombstone?(payload_kind) -> :recovery
      mtr?(payload_kind) and interactive?(traffic_class) -> :mtr_interactive
      mtr?(payload_kind) -> :mtr_bulk
      interactive?(traffic_class) -> :sweep_interactive
      true -> :sweep_bulk
    end
  end

  @doc "Primary data subject for a lane + partition, e.g. `sr.edge.v1.sweep.bulk.p07.v1`."
  @spec data_subject(lane(), non_neg_integer()) :: String.t()
  def data_subject(lane, partition) do
    "#{@root}.#{token(lane)}.p#{pad(partition)}.v#{@subject_version}"
  end

  @doc "Class-preserving DLQ subject for a lane + partition (distinct namespace)."
  @spec dlq_subject(lane(), non_neg_integer()) :: String.t()
  def dlq_subject(lane, partition) do
    "#{@root}.dlq.#{token(lane)}.p#{pad(partition)}.v#{@subject_version}"
  end

  @doc "Physical data-stream name for a lane."
  @spec physical_stream(lane()) :: String.t()
  def physical_stream(lane), do: "EDGE_#{stream_frag(lane)}_V#{@subject_version}"

  @doc "Physical DLQ-stream name for a lane, distinct from the data stream."
  @spec physical_dlq_stream(lane()) :: String.t()
  def physical_dlq_stream(lane), do: "EDGE_DLQ_#{stream_frag(lane)}_V#{@subject_version}"

  @doc "The routable lanes in a stable order."
  @spec routable_lanes() :: [lane()]
  def routable_lanes, do: [:sweep_bulk, :sweep_interactive, :mtr_bulk, :mtr_interactive, :recovery]

  # --- internals ---

  defp token(:sweep_bulk), do: "sweep.bulk"
  defp token(:sweep_interactive), do: "sweep.interactive"
  defp token(:mtr_bulk), do: "mtr.bulk"
  defp token(:mtr_interactive), do: "mtr.interactive"
  defp token(:recovery), do: "recovery"

  defp stream_frag(lane), do: lane |> token() |> String.upcase() |> String.replace(".", "_")

  defp pad(p), do: p |> Integer.to_string() |> String.pad_leading(2, "0")

  defp tombstone?(6), do: true
  defp tombstone?(:EDGE_RESULT_PAYLOAD_KIND_SPOOL_LOSS_TOMBSTONE_V1), do: true
  defp tombstone?(_), do: false

  defp mtr?(3), do: true
  defp mtr?(5), do: true
  defp mtr?(:EDGE_RESULT_PAYLOAD_KIND_MTR_TRACE_BATCH_V1), do: true
  defp mtr?(:EDGE_RESULT_PAYLOAD_KIND_LEGACY_MTR_JSON_V0), do: true
  defp mtr?(_), do: false

  defp interactive?(2), do: true
  defp interactive?(:EDGE_RESULT_TRAFFIC_CLASS_INTERACTIVE), do: true
  defp interactive?(_), do: false

  defp fnv1a_32(bin) do
    bin
    |> :binary.bin_to_list()
    |> Enum.reduce(@fnv_offset, fn byte, acc ->
      band(bxor(acc, byte) * @fnv_prime, @u32_mask)
    end)
  end
end
