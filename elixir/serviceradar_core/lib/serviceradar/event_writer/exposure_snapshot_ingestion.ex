defmodule ServiceRadar.EventWriter.ExposureSnapshotIngestion do
  @moduledoc "Retains an immutable write plan before admitting a snapshot warehouse effect."
  alias ServiceRadar.EventWriter.ExposureDelivery
  alias ServiceRadar.EventWriter.ExposureRecovery
  alias ServiceRadar.EventWriter.ExposureSnapshotEnvelope, as: Envelope
  alias ServiceRadar.EventWriter.ExposureSnapshotWarehouse, as: Warehouse
  alias ServiceRadar.Inventory.ExposureSnapshotRepairs, as: Repairs
  alias ServiceRadar.Inventory.ExposureSnapshotState, as: State
  alias ServiceRadar.Repo

  def receive_page(generation, envelope, hash, position) do
    lane = envelope["lane"]

    with {:ok, :ok} <-
           State.update_pending(generation["id"], lane, hash, fn state, pending ->
             if State.identity?(state, envelope) and pending["page"] == envelope["page"] do
               {:ok, Map.put(pending, "position", position), :ok}
             else
               {:error, :exposure_snapshot_identity_conflict}
             end
           end),
         :ok <-
           ExposureDelivery.with_lane(
             Envelope.lane(lane),
             fn locked ->
               prepare_and_settle(generation["id"], lane, envelope, hash, locked)
             end,
             snapshot: generation["id"]
           ),
         :ok <- repair_and_receipt(generation["id"], lane, hash) do
      cleanup(generation["id"], lane, hash)
    end
  end

  def release_unstarted(nil, _lane, _locked), do: :ok
  def release_unstarted(_id, lane, _locked) when lane > 15, do: :ok

  def release_unstarted(id, lane, locked) do
    with :ok <- locked.(),
         {:ok, :ok} <-
           State.change(id, fn generation ->
             if generation["scope"] == nil and generation["status"] == "publishing" do
               result =
                 Repo.query!(
                   """
                   DELETE FROM platform.exposure_delivery_batches
                   WHERE bucket = $1 AND phase = 'snapshot_required'
                   RETURNING cardinality(stream_sequences)
                   """,
                   [lane]
                 )

               count = Enum.reduce(result.rows, 0, fn [count], sum -> sum + count end)
               {:ok, Map.update!(generation, "history_gaps", &(&1 + count)), :ok}
             else
               {:ok, generation, :ok}
             end
           end),
         do: :ok
  end

  @doc "Called under a lane lock before admitting any live or snapshot writer."
  def settle(lane_number, locked) do
    lane = Enum.at(Envelope.lanes(), lane_number)

    case State.pending_for_lane(lane) do
      [] ->
        :ok

      [[id]] ->
        with {:ok, generation} <- State.get(id) do
          case generation["pending"][lane] do
            %{"state" => phase, "plan_hash" => _} = pending
            when phase in ["planning", "applying"] ->
              settle_plan(generation, lane, pending, locked)

            _ ->
              :ok
          end
        end
    end
  end

  defp prepare_and_settle(id, lane, envelope, hash, locked) do
    with {:ok, generation} <- State.get(id) do
      case generation["pending"][lane] do
        %{"hash" => ^hash, "state" => "reserved"} = pending ->
          if generation["status"] == "aborted" do
            mark_cleanup(id, lane, pending)
          else
            with :ok <- locked.(),
                 {:ok, plan} <- Warehouse.plan(generation, envelope),
                 body = Envelope.canonical(plan),
                 plan_hash = Envelope.digest(body),
                 true <- byte_size(body) <= 512 * 1024,
                 {:ok, :ok} <-
                   State.update_pending(id, lane, hash, fn state, current ->
                     if state["status"] == "publishing" and current["state"] == "reserved" do
                       next =
                         current
                         |> Map.put("state", "planning")
                         |> Map.put("plan_hash", plan_hash)
                         |> Map.put("plan_subject", current["subject"] <> ".plan." <> plan_hash)

                       {:ok, next, :ok}
                     else
                       {:error, :exposure_snapshot_page_changed}
                     end
                   end),
                 {:ok, latest} <- State.get(id) do
              retain_plan(latest, lane, latest["pending"][lane], body, locked)
            else
              false -> {:error, :exposure_snapshot_plan_too_large}
              error -> error
            end
          end

        %{"hash" => ^hash, "state" => phase} = pending when phase in ["planning", "applying"] ->
          settle_plan(generation, lane, pending, locked)

        %{"hash" => ^hash, "state" => phase} when phase in ["settled", "cleanup"] ->
          :ok

        _ ->
          {:error, :exposure_snapshot_page_changed}
      end
    end
  end

  defp settle_plan(generation, lane, pending, locked) do
    phase = pending["state"]

    case ExposureRecovery.fetch_envelope(
           pending["plan_subject"],
           pending["plan_hash"],
           pending["plan_position"]
         ) do
      {:ok, position, body} ->
        apply_retained(generation, lane, pending, position, body, locked)

      :missing when phase == "planning" ->
        # No warehouse call is allowed before the applying state. Reconstruct
        # only this unstarted plan from the retained source page.
        if generation["status"] == "aborted" do
          mark_cleanup(generation["id"], lane, pending)
        else
          with {:ok, _position, source} <-
                 ExposureRecovery.fetch_envelope(
                   pending["subject"],
                   pending["hash"],
                   pending["position"]
                 ),
               {:ok, envelope, _} <- Envelope.decode(source),
               {:ok, plan} <- Warehouse.plan(generation, envelope),
               body = Envelope.canonical(plan),
               true <- Envelope.digest(body) == pending["plan_hash"] do
            retain_plan(generation, lane, pending, body, locked)
          else
            false -> {:error, :exposure_snapshot_plan_conflict}
            error -> error
          end
        end

      :missing ->
        {:error, :exposure_snapshot_plan_lost}

      error ->
        error
    end
  end

  defp retain_plan(generation, lane, pending, body, locked) do
    with :ok <- locked.(),
         {:ok, position} <-
           ExposureRecovery.retain_envelope(pending["plan_subject"], body, pending["plan_hash"]) do
      apply_retained(generation, lane, pending, position, body, locked)
    end
  end

  defp apply_retained(generation, lane, pending, position, body, locked) do
    id = generation["id"]
    hash = pending["hash"]
    plan_hash = pending["plan_hash"]

    with {:ok, plan} <- Jason.decode(body),
         :ok <- locked.(),
         {:ok, decision} <-
           State.update_pending(id, lane, hash, fn state, current ->
             cond do
               current["plan_hash"] != plan_hash ->
                 {:error, :exposure_snapshot_page_changed}

               current["state"] == "planning" and state["status"] == "aborted" ->
                 {:ok,
                  current |> Map.put("state", "cleanup") |> Map.put("plan_position", position),
                  :abandon}

               current["state"] in ["planning", "applying"] ->
                 {:ok,
                  current |> Map.put("state", "applying") |> Map.put("plan_position", position),
                  :apply}

               true ->
                 {:error, :exposure_snapshot_page_changed}
             end
           end) do
      if decision == :abandon do
        :ok
      else
        with :ok <- Warehouse.apply_plan(plan, [id, lane, pending["page"]], locked),
             :ok <- locked.(),
             {:ok, :ok} <-
               State.update_pending(id, lane, hash, fn _state, current ->
                 if current["plan_hash"] == plan_hash and current["state"] == "applying" do
                   next =
                     current
                     |> Map.put("state", "settled")
                     |> Map.put("repairs", plan["repairs"])
                     |> Map.put("outcomes", Map.take(plan, ~w(post_snapshot retired)))

                   {:ok, next, :ok}
                 else
                   {:error, :exposure_snapshot_page_changed}
                 end
               end),
             do: :ok
      end
    end
  end

  defp repair_and_receipt(id, lane, hash) do
    with {:ok, generation} <- State.get(id) do
      case generation["pending"][lane] do
        %{"hash" => ^hash, "state" => "cleanup"} ->
          :ok

        %{"hash" => ^hash, "state" => "settled"} ->
          with :ok <- settle_repairs(generation, lane, hash),
               {:ok, _} <- State.receipt(id, lane, hash),
               do: :ok

        _ ->
          {:error, :exposure_snapshot_effects_pending}
      end
    end
  end

  defp settle_repairs(%{"status" => "aborted", "id" => id}, lane, hash) do
    # Applied effects have settled; an aborted view has no coverage to prove.
    with {:ok, :ok} <-
           State.update_pending(id, lane, hash, fn _state, pending ->
             {:ok, Map.put(pending, "repairs", []), :ok}
           end),
         do: :ok
  end

  defp settle_repairs(generation, lane, hash), do: Repairs.page(generation["id"], lane, hash)

  def cleanup(id, lane, hash) do
    with {:ok, generation} <- State.get(id) do
      case generation["pending"][lane] do
        %{"hash" => ^hash, "state" => "cleanup"} = pending ->
          with :ok <-
                 delete_input(
                   pending["plan_subject"],
                   pending["plan_hash"],
                   pending["plan_position"]
                 ),
               :ok <- delete_input(pending["subject"], hash, pending["position"]),
               {:ok, :ok} <- State.cleaned(id, lane, hash),
               do: :ok

        nil ->
          :ok

        _ ->
          {:error, :exposure_snapshot_effects_pending}
      end
    end
  end

  defp delete_input(nil, _hash, _position), do: :ok

  defp delete_input(_subject, _hash, position) when is_integer(position),
    do: ExposureRecovery.delete(position)

  defp delete_input(subject, hash, nil) do
    case ExposureRecovery.fetch_envelope(subject, hash) do
      {:ok, position, _body} -> ExposureRecovery.delete(position)
      :missing -> :ok
      error -> error
    end
  end

  defp mark_cleanup(id, lane, pending) do
    with {:ok, :ok} <-
           State.update_pending(id, lane, pending["hash"], fn state, current ->
             if state["status"] == "aborted" and current["state"] in ["reserved", "planning"] do
               {:ok, Map.put(current, "state", "cleanup"), :ok}
             else
               {:error, :exposure_snapshot_effects_pending}
             end
           end),
         do: :ok
  end

  @doc "Bounded maintenance also handles a crash before the producer received PubAck."
  def resume(id, lane) do
    with {:ok, generation} <- State.get(id) do
      case generation["pending"][lane] do
        nil ->
          :ok

        %{"state" => "cleanup", "hash" => hash} ->
          cleanup(id, lane, hash)

        pending ->
          aborted_unstarted = generation["status"] == "aborted" and pending["state"] == "reserved"

          case ExposureRecovery.fetch_envelope(
                 pending["subject"],
                 pending["hash"],
                 pending["position"]
               ) do
            {:ok, position, body} ->
              with {:ok, envelope, hash} <- Envelope.decode(body),
                   do: receive_page(generation, envelope, hash, position)

            :missing when aborted_unstarted ->
              with :ok <- mark_cleanup(id, lane, pending), do: cleanup(id, lane, pending["hash"])

            :missing ->
              {:error, :exposure_snapshot_input_lost}

            error ->
              error
          end
      end
    end
  end
end
