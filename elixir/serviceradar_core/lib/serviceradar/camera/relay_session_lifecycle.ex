defmodule ServiceRadar.Camera.RelaySessionLifecycle do
  @moduledoc """
  Synchronizes authenticated media ingress into persisted, fenced camera relays.

  Activation binds all forwarded assignment fields to the stored command.
  Genuine media heartbeats renew the owner using database time. Viewer-only
  updates manage independent leases and counts without extending ingest life.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.RelayOwnership
  alias ServiceRadar.Camera.RelaySession

  @assignment_fields [:agent_id, :gateway_id, :camera_source_id, :stream_profile_id]

  def activate_session(id, ingest_id, attrs \\ %{}, opts \\ []) do
    opts = caller(opts)

    RelayOwnership.with_session(
      id,
      fn owner, session ->
        with :ok <- valid_ingest(ingest_id),
             :ok <- ensure_status(session, [:requested, :opening, :active]),
             :ok <- ensure_assignment(session, attrs),
             :ok <- ensure_ingest(session, ingest_id),
             {:ok, incarnation} <- source_incarnation(attrs),
             :ok <- ensure_incarnation(session, incarnation) do
          sync_media(
            owner,
            session,
            ingest_id,
            Map.put(attrs, :source_incarnation_id, incarnation),
            opts
          )
        end
      end,
      opts
    )
  end

  def heartbeat_session(id, ingest_id, attrs \\ %{}, opts \\ []) do
    opts = caller(opts)

    RelayOwnership.with_session(
      id,
      fn owner, session ->
        with :ok <- valid_ingest(ingest_id),
             :ok <- ensure_status(session, [:opening, :active, :closing]),
             :ok <- ensure_ingest(session, ingest_id) do
          cond do
            session.status == :closing ->
              {:ok, session}

            Map.get(attrs, :renew_ingest?, true) ->
              sync_media(owner, session, ingest_id, attrs, opts)

            true ->
              sync_viewers(owner, session, attrs, opts)
          end
        end
      end,
      opts
    )
  end

  def close_session(id, ingest_id, attrs \\ %{}, opts \\ []) do
    finish_session(id, ingest_id, attrs, :closed, caller(opts))
  end

  def fail_session(id, ingest_id, attrs \\ %{}, opts \\ []) do
    finish_session(id, ingest_id, attrs, :failed, caller(opts))
  end

  defp sync_media(owner, session, ingest_id, attrs, opts) do
    case RelayOwnership.adopt(owner, session, opts) do
      {:ok, lease} ->
        with {:ok, renewed} <- RelayOwnership.renew(lease, opts),
             :ok <- RelayOwnership.sync_viewers(renewed, attrs, opts) do
          persist_media(session, ingest_id, renewed.lease_expires_at, attrs, opts)
        end

      {:error, :ambiguous_live_relays} = error ->
        if session.status == :active and session.media_ingest_id == ingest_id and
             is_binary(ingest_id) and ingest_id != "" do
          # Only pre-existing authenticated streams survive ambiguous upgrade
          # state; no ownership handle or consumer lease is issued here.
          expiry = DateTime.shift(owner.database_now, second: 30)
          persist_media(session, ingest_id, expiry, attrs, opts)
        else
          error
        end

      {:error, _} = error ->
        error
    end
  end

  defp sync_viewers(owner, session, attrs, opts) do
    if RelayOwnership.current?(owner, session) do
      with :ok <- RelayOwnership.sync_viewers(owner, attrs, opts),
           do:
             RelaySession.renew_lease(
               session,
               %{viewer_count: normalize_viewer_count(attrs, session.viewer_count)},
               opts
             )
    else
      {:error, :ownership_lost}
    end
  end

  defp persist_media(session, ingest_id, expiry, attrs, opts) do
    lease = %{
      lease_expires_at: expiry,
      viewer_count: normalize_viewer_count(attrs, session.viewer_count)
    }

    if session.status == :active,
      do: RelaySession.renew_lease(session, lease, opts),
      else:
        RelaySession.activate(
          session,
          Map.merge(lease, %{
            media_ingest_id: ingest_id,
            source_incarnation_id: attrs[:source_incarnation_id]
          }),
          opts
        )
  end

  defp finish_session(id, ingest_id, attrs, status, opts) do
    RelayOwnership.with_session(
      id,
      fn owner, session ->
        with :ok <- ensure_ingest(session, ingest_id) do
          if session.status in [:closed, :failed] do
            {:ok, session}
          else
            updates = %{
              close_reason: close_reason(session, attrs),
              viewer_count: normalize_viewer_count(attrs, 0)
            }

            result =
              if status == :closed,
                do: RelaySession.mark_closed(session, updates, opts),
                else:
                  RelaySession.fail_session(
                    session,
                    Map.put(updates, :failure_reason, failure_reason(attrs)),
                    opts
                  )

            with {:ok, updated} <- result,
                 {:ok, _retired} <- RelayOwnership.retire_bound(owner, session, opts),
                 do: {:ok, updated}
          end
        end
      end,
      opts
    )
  end

  defp source_incarnation(attrs) do
    case Map.get(attrs, :source_incarnation_id) do
      legacy when legacy in [nil, ""] ->
        {:ok, nil}

      value when is_binary(value) and byte_size(value) == 36 ->
        case Ecto.UUID.cast(value) do
          {:ok, id} -> {:ok, id}
          :error -> {:error, :invalid_source_incarnation}
        end

      _ ->
        {:error, :invalid_source_incarnation}
    end
  end

  # Bind once. A new runtime cannot inherit an active relay, including a legacy
  # relay whose runtime is unknown. Neither mismatch nor absence proves retirement.
  defp ensure_incarnation(%{status: status, source_incarnation_id: nil}, _incarnation)
       when status in [:requested, :opening], do: :ok

  defp ensure_incarnation(%{source_incarnation_id: id}, id), do: :ok
  defp ensure_incarnation(_session, _incarnation), do: {:error, :source_incarnation_mismatch}

  defp valid_ingest(id) when is_binary(id) and id != "", do: :ok
  defp valid_ingest(_), do: {:error, :media_ingest_mismatch}

  defp ensure_assignment(session, attrs) do
    matches? =
      Enum.all?(@assignment_fields, fn field ->
        value = Map.get(attrs, field)
        is_binary(value) and value != "" and value == Map.get(session, field)
      end)

    if matches?, do: :ok, else: {:error, :relay_assignment_mismatch}
  end

  defp ensure_status(session, statuses) do
    if session.status in statuses, do: :ok, else: {:error, {:invalid_status, session.status}}
  end

  defp ensure_ingest(%{media_ingest_id: stored}, incoming) when stored in [nil, ""] do
    if is_nil(incoming) or (is_binary(incoming) and incoming != ""),
      do: :ok,
      else: {:error, :media_ingest_mismatch}
  end

  defp ensure_ingest(%{media_ingest_id: id}, id), do: :ok
  defp ensure_ingest(_session, _id), do: {:error, :media_ingest_mismatch}

  defp close_reason(session, attrs) when is_map(attrs) do
    existing_reason = existing_close_reason(session)
    incoming_reason = Map.get(attrs, :close_reason)

    if preserve_existing_close_reason?(session, incoming_reason, existing_reason) do
      existing_reason
    else
      blank_to_default(incoming_reason, existing_reason || "media ingress closed")
    end
  end

  defp close_reason(session, _attrs), do: existing_close_reason(session) || "media ingress closed"

  defp normalize_viewer_count(attrs, default) when is_map(attrs) do
    value = Map.get(attrs, :viewer_count, default)
    if is_integer(value) and value >= 0, do: value, else: default
  end

  defp normalize_viewer_count(_attrs, default), do: default

  defp failure_reason(attrs) when is_map(attrs) do
    attrs
    |> Map.get(:failure_reason)
    |> blank_to_default("media ingress failure")
  end

  defp failure_reason(_attrs), do: "media ingress failure"

  defp blank_to_default(value, default) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: default, else: value
  end

  defp blank_to_default(nil, default), do: default
  defp blank_to_default(value, _default), do: to_string(value)

  defp existing_close_reason(session) when is_map(session) do
    session
    |> Map.get(:close_reason)
    |> case do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      value when not is_nil(value) ->
        to_string(value)

      _ ->
        nil
    end
  end

  defp preserve_existing_close_reason?(session, incoming_reason, existing_reason) do
    closing_session?(session) and present_reason?(existing_reason) and
      drain_ack_reason?(incoming_reason)
  end

  defp closing_session?(session) when is_map(session) do
    Map.get(session, :status) in [:closing, "closing"]
  end

  defp present_reason?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_reason?(nil), do: false

  defp drain_ack_reason?(value) when is_binary(value) do
    String.trim(value) == "camera relay drain acknowledged"
  end

  defp drain_ack_reason?(_value), do: false

  defp caller(opts),
    do: [actor: Keyword.get(opts, :actor, SystemActor.system(:camera_relay_session_lifecycle))]
end
