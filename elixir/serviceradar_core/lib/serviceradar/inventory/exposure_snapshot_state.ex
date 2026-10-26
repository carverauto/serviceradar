defmodule ServiceRadar.Inventory.ExposureSnapshotState do
  @moduledoc "Durable snapshot control: eighteen receipts and at most one pending page per lane."
  alias ServiceRadar.EventWriter.ExposureSnapshotEnvelope, as: Envelope
  alias ServiceRadar.Repo

  @table "platform.exposure_snapshot_generations"

  def create(scope, snapshot, owner, deadline) do
    control = %{
      "scope" => scope,
      "snapshot" => snapshot,
      "owner" => owner,
      "deadline" => deadline,
      "started" => false,
      "phase" => "dimensions",
      "receipts" => Envelope.empty_manifest(),
      "pending" => %{},
      "cursor" => [0, 0, 0],
      "repairs" => [],
      "history_gaps" => 0,
      "outcomes" => %{"post_snapshot" => 0, "retired" => 0}
    }

    case Repo.query(
           """
           INSERT INTO #{@table} (status, control, inserted_at, updated_at)
           VALUES ('publishing', $1, now(), now()) RETURNING id
           """,
           [control]
         ) do
      {:ok, %{rows: [[id]]}} -> get(id)
      {:error, reason} -> {:error, reason}
    end
  end

  def get(id) do
    case Repo.query("SELECT status, control FROM #{@table} WHERE id = $1", [id]) do
      {:ok, %{rows: [[status, control]]}} -> {:ok, identify(control, id, status)}
      {:ok, %{rows: []}} -> {:error, :exposure_snapshot_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def active do
    case Repo.query!("SELECT id FROM #{@table} WHERE status NOT IN ('complete', 'aborted')").rows do
      [] -> :none
      [[id]] -> get(id)
    end
  end

  @doc "Short row-locked metadata mutation; warehouse calls never run inside this transaction."
  def change(id, fun) do
    Repo.transaction(fn ->
      case Repo.query!("SELECT status, control FROM #{@table} WHERE id = $1 FOR UPDATE", [id]).rows do
        [[status, control]] ->
          case fun.(identify(control, id, status)) do
            {:ok, next, result} ->
              Repo.query!(
                "UPDATE #{@table} SET status = $2, control = $3, updated_at = now() WHERE id = $1",
                [id, next["status"], Map.drop(next, ["id", "status"])]
              )

              result

            {:error, reason} ->
              Repo.rollback(reason)
          end

        [] ->
          Repo.rollback(:exposure_snapshot_not_found)
      end
    end)
  end

  def reserve(id, owner, envelope, hash) do
    change(id, fn state ->
      lane = envelope["lane"]
      pending = state["pending"][lane]

      with :ok <- publishing(state, owner),
           true <- state["started"] and envelope["phase"] == state["phase"],
           true <- identity?(state, envelope),
           {:ok, _} <- Envelope.advance(state["receipts"][lane], envelope, hash) do
        cond do
          pending && pending["hash"] == hash ->
            {:ok, state, pending}

          pending != nil ->
            {:error, :exposure_snapshot_page_pending}

          envelope["page"] != state["receipts"][lane]["page"] + 1 ->
            {:error, :exposure_snapshot_receipt_conflict}

          true ->
            metadata =
              envelope
              |> Map.take(~w(lane page phase count previous))
              |> Map.merge(%{
                "hash" => hash,
                "subject" => Envelope.subject(id, lane, envelope["page"]),
                "state" => "reserved",
                "repairs" => []
              })

            {:ok, put_in(state, ["pending", lane], metadata), metadata}
        end
      else
        false -> {:error, :exposure_snapshot_phase_conflict}
        error -> error
      end
    end)
  end

  def update_pending(id, lane, hash, fun) do
    change(id, fn state ->
      case state["pending"][lane] do
        %{"hash" => ^hash} = pending ->
          case fun.(state, pending) do
            {:ok, next, result} -> {:ok, put_in(state, ["pending", lane], next), result}
            error -> error
          end

        _ ->
          {:error, :exposure_snapshot_page_changed}
      end
    end)
  end

  def receipt(id, lane, hash) do
    change(id, fn state ->
      case state["pending"][lane] do
        %{"hash" => ^hash, "state" => "settled", "repairs" => []} = pending ->
          if state["status"] == "publishing" do
            with {:ok, receipt} <- Envelope.advance(state["receipts"][lane], pending, hash) do
              next =
                state
                |> put_in(["receipts", lane], receipt)
                |> put_in(["pending", lane, "state"], "cleanup")
                |> Map.update!("outcomes", fn totals ->
                  Map.merge(totals, pending["outcomes"] || %{}, fn _key, left, right ->
                    left + right
                  end)
                end)

              {:ok, next, :ok}
            end
          else
            {:ok, put_in(state, ["pending", lane, "state"], "cleanup"), :aborted}
          end

        %{"hash" => ^hash, "state" => "cleanup"} ->
          {:ok, state, :ok}

        _ ->
          {:error, :exposure_snapshot_effects_pending}
      end
    end)
  end

  def cleaned(id, lane, hash) do
    change(id, fn state ->
      case state["pending"][lane] do
        %{"hash" => ^hash, "state" => "cleanup"} ->
          {:ok, update_in(state, ["pending"], &Map.delete(&1, lane)), :ok}

        nil ->
          {:ok, state, :ok}

        _ ->
          {:error, :exposure_snapshot_effects_pending}
      end
    end)
  end

  def phase(id, owner, phase) do
    change(id, fn state ->
      with :ok <- publishing(state, owner),
           true <- state["pending"] == %{},
           true <-
             {state["phase"], phase} in [{"dimensions", "lifecycle"}, {"lifecycle", "facts"}] do
        {:ok, Map.put(state, "phase", phase), :ok}
      else
        false -> {:error, :exposure_snapshot_phase_pending}
        error -> error
      end
    end)
  end

  def end_manifest(id, owner, manifest) do
    change(id, fn state ->
      with :ok <- publishing(state, owner),
           true <- state["phase"] == "facts" and state["pending"] == %{},
           true <- state["receipts"] == manifest do
        next = state |> Map.put("status", "published") |> Map.put("manifest", manifest)
        {:ok, next, next}
      else
        false -> {:error, :exposure_snapshot_incomplete}
        error -> error
      end
    end)
  end

  def abort(id, owner, reason) do
    change(id, fn state ->
      if state["owner"] == owner and state["status"] == "publishing" do
        next = state |> Map.put("status", "aborted") |> Map.put("abort_reason", to_string(reason))
        {:ok, next, :ok}
      else
        {:error, :exposure_snapshot_owner_changed}
      end
    end)
  end

  def pending_for_lane(lane) do
    Repo.query!(
      "SELECT id FROM #{@table} WHERE control->'pending' ? $1 ORDER BY id LIMIT 1",
      [lane]
    ).rows
  end

  def unsettled? do
    Repo.query!("SELECT 1 FROM #{@table} WHERE control->'pending' <> '{}'::jsonb LIMIT 1").rows !=
      []
  end

  def publishing(state, owner) do
    if state["owner"] == owner and state["status"] == "publishing" and
         System.system_time(:millisecond) < state["deadline"] do
      :ok
    else
      {:error, :exposure_snapshot_producer_expired}
    end
  end

  def identity?(state, envelope) do
    envelope["generation"] == state["id"] and envelope["scope"] == state["scope"] and
      envelope["fence"] == Envelope.digest(state["snapshot"])
  end

  defp identify(control, id, status), do: Map.merge(control, %{"id" => id, "status" => status})
end
