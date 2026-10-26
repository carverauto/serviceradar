defmodule ServiceRadar.EventWriter.Processors.ExposureSnapshots do
  @moduledoc "Consumes retained start/page/end envelopes; an end marker alone never completes a generation."
  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.EventWriter.ExposureDelivery
  alias ServiceRadar.EventWriter.ExposureRecovery
  alias ServiceRadar.EventWriter.ExposureSnapshotEnvelope, as: Envelope
  alias ServiceRadar.EventWriter.ExposureSnapshotIngestion, as: Ingestion
  alias ServiceRadar.Inventory.ExposureSnapshotState, as: State

  @impl true
  def table_name, do: "exposure_facts"

  @impl true
  def process_batch(messages) do
    if Destination.enabled?() do
      Enum.reduce_while(messages, {:ok, 0}, fn message, {:ok, count} ->
        case consume(message) do
          :ok -> {:cont, {:ok, count + 1}}
          error -> {:halt, error}
        end
      end)
    else
      {:error, :starrocks_required}
    end
  end

  defp consume(%{
         data: body,
         metadata: %{
           subject: subject,
           jetstream_ack: %{stream: "EXPOSURE_RECOVERY", stream_sequence: position}
         }
       })
       when is_integer(position) and position > 0 do
    if String.contains?(subject, ".plan.") do
      plan_notice(subject, body, position)
    else
      with {:ok, envelope, hash} <- Envelope.decode(body),
           {:ok, generation} <- State.get(envelope["generation"]),
           true <- State.identity?(generation, envelope),
           true <- subject == subject(envelope) do
        receive_envelope(generation, envelope, hash, position)
      else
        false -> {:error, :exposure_snapshot_identity_conflict}
        error -> error
      end
    end
  end

  defp consume(_), do: {:error, :invalid_exposure_snapshot_message}

  defp receive_envelope(generation, %{"kind" => "start"} = envelope, _hash, position) do
    with true <- generation["snapshot"] == envelope["snapshot"],
         :ok <- admit_start(generation),
         {:ok, :ok} <-
           State.change(generation["id"], fn state ->
             next =
               if state["status"] == "publishing",
                 do: Map.put(state, "started", true),
                 else: state

             {:ok, next, :ok}
           end),
         :ok <- ExposureRecovery.delete(position) do
      :ok
    else
      false -> {:error, :exposure_snapshot_identity_conflict}
      error -> error
    end
  end

  defp admit_start(%{"scope" => nil, "status" => "publishing", "started" => false, "id" => id}) do
    Enum.reduce_while(0..15, :ok, fn bucket, :ok ->
      case ExposureDelivery.with_lane(bucket, fn owned -> owned.() end, snapshot: id) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp admit_start(_generation), do: :ok

  defp receive_envelope(generation, %{"kind" => "end", "manifest" => manifest}, _hash, position) do
    with {:ok, :ok} <-
           State.change(generation["id"], fn state ->
             cond do
               state["status"] == "aborted" ->
                 {:ok, state, :ok}

               state["status"] in ["published", "finalizing", "complete"] and
                 state["manifest"] == manifest and state["receipts"] == manifest and
                   state["pending"] == %{} ->
                 next =
                   if state["status"] == "published",
                     do: Map.put(state, "status", "finalizing"),
                     else: state

                 {:ok, next, :ok}

               true ->
                 {:error, :exposure_snapshot_incomplete}
             end
           end),
         do: ExposureRecovery.delete(position)
  end

  defp receive_envelope(generation, envelope, hash, position) do
    lane = envelope["lane"]
    pending = generation["pending"][lane]

    cond do
      pending && pending["hash"] == hash ->
        Ingestion.receive_page(generation, envelope, hash, position)

      generation["status"] in ["aborted", "complete"] ->
        ExposureRecovery.delete(position)

      envelope["page"] <= generation["receipts"][lane]["page"] ->
        # Old pages never advance a receipt. The current page still checks its
        # hash; older pages have no remaining warehouse effects to admit.
        if envelope["page"] == generation["receipts"][lane]["page"] and
             hash != generation["receipts"][lane]["digest"] do
          {:error, :exposure_snapshot_receipt_conflict}
        else
          ExposureRecovery.delete(position)
        end

      true ->
        {:error, :exposure_snapshot_page_not_reserved}
    end
  end

  # A plan is retained input for the owning page, not a second delivery. Late
  # publications after cancellation are removed even after their caller died.
  defp plan_notice(subject, body, position) do
    with ["exposure", "snapshots", generation, lane, page, "plan", hash] <-
           String.split(subject, "."),
         {id, ""} <- Integer.parse(generation),
         {page, ""} <- Integer.parse(page),
         true <- Envelope.digest(body) == hash,
         {:ok, state} <- State.get(id) do
      case state["pending"][lane] do
        %{"page" => ^page, "plan_hash" => ^hash} -> :ok
        _ -> ExposureRecovery.delete(position)
      end
    else
      _ -> {:error, :invalid_exposure_snapshot_plan}
    end
  end

  defp subject(%{"kind" => kind, "generation" => id}), do: "exposure.snapshots.#{id}.#{kind}"

  defp subject(envelope),
    do: Envelope.subject(envelope["generation"], envelope["lane"], envelope["page"])
end
