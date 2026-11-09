defmodule ServiceRadar.Edge.RecoveryOperationTest do
  use ExUnit.Case, async: true

  alias Monitoring.EdgeRecoveryCopy
  alias Monitoring.EdgeRecoveryRegistration
  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.RecoveryOperation
  alias Serviceradar.Edge.V1.EdgeClassificationSpanV1
  alias Serviceradar.Edge.V1.EdgeLossManifestPageV1
  alias Serviceradar.Edge.V1.EdgeUnattributableV1
  alias Serviceradar.Edge.V1.SpoolLossTombstoneV1

  test "loss union and preserved coordinates partition allocation, including a gap between losses" do
    operation = operation([loss(9, 9), loss(11, 11)], [copy(10, 1)], 9, 11)

    assert {:ok, %{registration: ^operation, pages: [page]}} =
             RecoveryOperation.validate(operation)

    assert [%{from_sequence: 9, through_sequence: 9}, %{from_sequence: 11, through_sequence: 11}] =
             page.classification_spans
  end

  test "markerless allocated sequence cannot disappear behind committed sequence nine" do
    incomplete = operation([loss(9, 9)], [], 9, 10)
    assert {:error, :allocation_coverage} = RecoveryOperation.validate(incomplete)
    assert {:ok, _} = RecoveryOperation.validate(operation([loss(9, 10)], [], 9, 10))
  end

  test "copy cannot overlap loss or reuse destination coordinates" do
    overlap = operation([loss(9, 11)], [copy(10, 1)], 9, 11)
    assert {:error, :allocation_coverage} = RecoveryOperation.validate(overlap)

    reused = operation([loss(9, 9)], [copy(10, 1), copy(11, 1)], 9, 11)
    assert {:error, :copy_manifest} = RecoveryOperation.validate(reused)
  end

  test "registration binds the tombstone spool pair and selected frozen allocation bounds" do
    valid = operation([loss(9, 10)], [], 9, 10)

    assert {:error, :registration_tombstone} =
             RecoveryOperation.validate(%{valid | new_spool_id: uuid(8)})

    assert {:error, :registration_identity} =
             RecoveryOperation.validate(%{valid | source_high_water: 9})

    assert {:error, :registration_identity} =
             RecoveryOperation.validate(%{valid | source_reclaim_watermark: 9})

    assert {:error, :registration_identity} =
             RecoveryOperation.validate(%{valid | protocol_version: 2})
  end

  test "received page bytes are bounded before decode even when duplicate fields would collapse" do
    valid = operation([loss(9, 10)], [], 9, 10)
    [page] = valid.manifest_pages
    # Repeated page_index=0 fields change received size without changing decoded state.
    oversized = page <> :binary.copy(<<16, 0>>, 128 * 1024)

    assert {:error, :registration_bounds} =
             RecoveryOperation.validate(%{valid | manifest_pages: [oversized]})
  end

  defp operation(spans, copies, first, last) do
    page = %EdgeLossManifestPageV1{
      recovery_id: uuid(1),
      page_index: 0,
      page_count: 1,
      terminal: true,
      digest_version: 1,
      classification_spans: spans
    }

    page = %{page | page_sha256: HashGrammar.manifest_page_digest(page)}

    tombstone = %SpoolLossTombstoneV1{
      recovery_id: uuid(1),
      prior_spool_id: uuid(2),
      new_spool_id: uuid(3),
      manifest_root_sha256: HashGrammar.manifest_root([page]),
      manifest_page_count: 1,
      detected_at_unix_nano: 1_800_000_000_000_000_000,
      reason: "synthetic_torn_append",
      digest_version: 1
    }

    %EdgeRecoveryRegistration{
      protocol_version: 1,
      network_scope_id: uuid(4),
      recovery_id: uuid(1),
      prior_spool_id: uuid(2),
      new_spool_id: uuid(3),
      route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
      traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
      source_reclaim_watermark: first - 1,
      source_high_water: last,
      from_sequence: first,
      through_sequence: last,
      copies: copies,
      manifest_pages: [EdgeLossManifestPageV1.encode(page)],
      tombstone: SpoolLossTombstoneV1.encode(tombstone)
    }
  end

  defp loss(first, last),
    do: %EdgeClassificationSpanV1{
      from_sequence: first,
      through_sequence: last,
      classification:
        {:unattributable, %EdgeUnattributableV1{reason: :EDGE_UNATTRIBUTABLE_REASON_TORN_TAIL}}
    }

  defp copy(prior, new),
    do: %EdgeRecoveryCopy{
      prior_sequence: prior,
      new_sequence: new,
      event_id: uuid(prior),
      record_sha256: :binary.copy(<<21>>, 32),
      attribution_binding_sha256: :binary.copy(<<22>>, 32)
    }

  defp uuid(value), do: <<value::48, 7::4, 0::12, 2::2, value::62>>
end
