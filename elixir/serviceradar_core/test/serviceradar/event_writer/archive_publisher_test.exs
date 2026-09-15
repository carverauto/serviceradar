defmodule ServiceRadar.EventWriter.ArchivePublisherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.ArchiveBatch
  alias ServiceRadar.ColdTier.Registry
  alias ServiceRadar.EventWriter.ArchivePublisher

  @time ~U[2025-03-02 01:00:00Z]

  defp batch do
    columns = Enum.map(Registry.fetch!("timeseries_metrics").columns, &elem(&1, 0))

    row =
      Map.merge(Map.new(columns, &{&1, nil}), %{
        "timestamp" => @time,
        "gateway_id" => "synthetic-gateway",
        "series_key" => "synthetic-series",
        "metric_name" => "synthetic_metric",
        "metric_type" => "gauge",
        "value" => 12.5
      })

    {:ok, [batch]} = ArchiveBatch.prepare_batches("timeseries_metrics", [row])
    Map.put(batch, :state, :pending)
  end

  test "published batches skip all archive IO on retry" do
    batch = %{batch() | state: :published}

    assert :ok =
             ArchivePublisher.publish(batch.id,
               load_batch: fn _ -> {:ok, batch} end,
               writer: fn _, _, _ -> flunk("published batch must not be rewritten") end
             )
  end

  test "each attempt gets a fresh candidate while completion retains the logical batch ID" do
    owner = self()
    batch = batch()

    opts = [
      load_batch: fn id ->
        assert id == batch.id
        {:ok, batch}
      end,
      writer: fn "timeseries_metrics", [row], opts ->
        assert row.series_key == "synthetic-series"
        assert opts[:candidate] == true
        send(owner, {:candidate, opts[:batch_id]})
        assert :ok = opts[:record_manifest].(%{object_key: "synthetic-candidate"})
        {:ok, 1}
      end,
      complete_batch: fn id, attrs, _ ->
        assert id == batch.id
        assert attrs.object_key == "synthetic-candidate"
        :ok
      end
    ]

    assert :ok = ArchivePublisher.publish(batch.id, opts)
    assert :ok = ArchivePublisher.publish(batch.id, opts)
    assert_received {:candidate, first}
    assert_received {:candidate, second}
    assert first != second
    assert first != batch.id
    assert second != batch.id
  end

  test "failed archive writes retain the durable batch for retry" do
    batch = batch()

    assert {:error, :archive_unavailable} =
             ArchivePublisher.publish(batch.id,
               load_batch: fn _ -> {:ok, batch} end,
               writer: fn _, _, _ -> {:error, :archive_unavailable} end,
               complete_batch: fn _, _, _ -> flunk("failed upload must not complete") end
             )
  end

  test "corrupt payloads never reach the writer" do
    batch = %{batch() | payload: "invalid"}

    assert {:error, :invalid_archive_payload} =
             ArchivePublisher.publish(batch.id,
               load_batch: fn _ -> {:ok, batch} end,
               writer: fn _, _, _ -> flunk("corrupt payload must not upload") end
             )
  end

  test "reconciliation re-enqueues pending IDs and propagates enqueue failure" do
    owner = self()

    assert :ok =
             ArchivePublisher.reconcile_pending(
               pending_ids: fn 100 -> {:ok, ["first", "second"]} end,
               enqueue_job: fn id ->
                 send(owner, {:queued, id})
                 {:ok, :job}
               end,
               mark_reconciled: fn id ->
                 send(owner, {:reconciled, id})
                 :ok
               end
             )

    assert_received {:queued, "first"}
    assert_received {:queued, "second"}
    assert_received {:reconciled, "first"}
    assert_received {:reconciled, "second"}

    assert {:error, :queue_unavailable} =
             ArchivePublisher.reconcile_pending(
               pending_ids: fn 100 -> {:ok, ["first"]} end,
               enqueue_job: fn _ -> {:error, :queue_unavailable} end,
               mark_reconciled: fn _ ->
                 flunk("failed enqueue must not move the batch behind other work")
               end
             )
  end
end
