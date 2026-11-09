defmodule ServiceRadar.Edge.RecoveryOperation do
  @moduledoc """
  Validates an immutable, bounded recovery registration before authority is issued.

  Allocation bounds are independent of the loss union. Copies and losses must
  partition the selected interval exactly; a manifest's extent cannot fill a hole.
  Registration records intended copies, not their local durability. The agent's
  coverage owner must still prove destination commits before deleting any source.
  """

  alias Monitoring.EdgeRecoveryCopy
  alias Monitoring.EdgeRecoveryRegistration
  alias ServiceRadar.Edge.BoundedList
  alias ServiceRadar.Edge.RecoveryValidate
  alias Serviceradar.Edge.V1.EdgeRecoveryControlPayloadV1
  alias ServiceRadar.Edge.WireDecode

  @protocol_version 1
  @max_slots 1024
  @max_registration_bytes 512 * 1024
  @max_manifest_bytes 256 * 1024

  def protocol_version, do: @protocol_version
  def max_slots, do: @max_slots

  @doc "Validate the operation, retaining exact received page and tombstone bytes."
  def validate(%EdgeRecoveryRegistration{} = registration) do
    with :ok <- identity(registration),
         :ok <- bounds(registration),
         {:ok, tombstone} <- WireDecode.decode_spool_loss_tombstone(registration.tombstone),
         {:ok, _} <-
           RecoveryValidate.control_body(%EdgeRecoveryControlPayloadV1{
             body: {:tombstone, tombstone}
           }),
         :ok <- tombstone_identity(registration, tombstone),
         :ok <-
           RecoveryValidate.manifest_chain_from_raw(
             registration.manifest_pages,
             tombstone.manifest_root_sha256
           ),
         {:ok, pages} <- decode_pages(registration.manifest_pages),
         :ok <- RecoveryValidate.tombstone(tombstone, pages),
         :ok <- copies(registration.copies),
         :ok <- partition(registration, pages) do
      {:ok, %{registration: registration, tombstone: tombstone, pages: pages}}
    end
  end

  def validate(_registration), do: {:error, :registration_shape}

  defp bounds(r) do
    with true <- BoundedList.within?(r.manifest_pages, 1024),
         true <- BoundedList.within?(r.copies, @max_slots),
         true <- is_binary(r.tombstone) and byte_size(r.tombstone) <= @max_manifest_bytes,
         true <-
           Enum.all?(r.manifest_pages, &(is_binary(&1) and byte_size(&1) <= @max_manifest_bytes)),
         true <- Enum.reduce(r.manifest_pages, 0, &(byte_size(&1) + &2)) <= @max_manifest_bytes,
         true <- r.__unknown_fields__ == [],
         true <- Enum.all?(r.copies, &copy_shape?/1),
         true <- byte_size(EdgeRecoveryRegistration.encode(r)) <= @max_registration_bytes do
      :ok
    else
      _ -> {:error, :registration_bounds}
    end
  end

  defp identity(r) do
    valid =
      r.protocol_version == @protocol_version and uuid?(r.network_scope_id) and
        uuidv7?(r.recovery_id) and uuidv7?(r.prior_spool_id) and uuidv7?(r.new_spool_id) and
        r.prior_spool_id != r.new_spool_id and valid_lane?(r) and
        uint64?(r.source_reclaim_watermark) and uint64?(r.source_high_water) and
        uint64?(r.from_sequence) and uint64?(r.through_sequence) and
        r.from_sequence > r.source_reclaim_watermark and r.from_sequence <= r.through_sequence and
        r.through_sequence <= r.source_high_water and
        r.through_sequence - r.from_sequence < @max_slots

    check(valid, :registration_identity)
  end

  defp valid_lane?(r) do
    r.route_profile in [
      :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
      :EDGE_RECORD_ROUTE_PROFILE_CONTINUOUS_V1,
      :EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1
    ] and
      r.traffic_class in [:EDGE_RECORD_TRAFFIC_CLASS_BULK, :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE]
  end

  defp tombstone_identity(r, t) do
    check(
      t.recovery_id == r.recovery_id and t.prior_spool_id == r.prior_spool_id and
        t.new_spool_id == r.new_spool_id,
      :registration_tombstone
    )
  end

  defp decode_pages(raw) do
    raw
    |> Enum.reduce_while({:ok, []}, fn bytes, {:ok, pages} ->
      case WireDecode.decode_manifest_page(bytes) do
        {:ok, page} -> {:cont, {:ok, [page | pages]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pages} -> {:ok, Enum.reverse(pages)}
      error -> error
    end
  end

  defp copies(copies) do
    sequences = Enum.map(copies, & &1.prior_sequence)
    destinations = Enum.map(copies, & &1.new_sequence)

    check(
      sequences == Enum.sort(Enum.uniq(sequences)) and
        length(destinations) == MapSet.size(MapSet.new(destinations)),
      :copy_manifest
    )
  end

  defp copy_shape?(%EdgeRecoveryCopy{} = c),
    do:
      c.__unknown_fields__ == [] and uint64?(c.prior_sequence) and c.prior_sequence > 0 and
        uint64?(c.new_sequence) and
        c.new_sequence > 0 and uuidv7?(c.event_id) and digest?(c.record_sha256) and
        digest?(c.attribution_binding_sha256)

  defp copy_shape?(_copy), do: false

  defp partition(r, pages) do
    losses =
      for page <- pages,
          span <- page.classification_spans,
          do: {span.from_sequence, span.through_sequence}

    preserved = Enum.map(r.copies, &{&1.prior_sequence, &1.prior_sequence})

    (losses ++ preserved)
    |> Enum.sort()
    |> Enum.reduce_while({:ok, r.from_sequence}, fn {first, last}, {:ok, next} ->
      if first == next and last <= r.through_sequence,
        do: {:cont, {:ok, last + 1}},
        else: {:halt, {:error, :allocation_coverage}}
    end)
    |> case do
      {:ok, next} -> check(next == r.through_sequence + 1, :allocation_coverage)
      error -> error
    end
  end

  defp uint64?(value),
    do: is_integer(value) and value >= 0 and value <= 18_446_744_073_709_551_615

  defp digest?(value), do: is_binary(value) and byte_size(value) == 32
  defp uuid?(<<_::48, version::4, _::12, 2::2, _::62>>), do: version in 1..8
  defp uuid?(_value), do: false
  defp uuidv7?(<<_::48, 7::4, _::12, 2::2, _::62>>), do: true
  defp uuidv7?(_value), do: false
  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
