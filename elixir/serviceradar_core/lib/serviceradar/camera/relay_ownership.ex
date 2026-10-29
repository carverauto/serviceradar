defmodule ServiceRadar.Camera.RelayOwnership do
  @moduledoc """
  Couples persisted relay transitions to the camera/profile ownership fence.

  Reservations commit before dispatching external agent commands. A command can
  arrive late, but activation must still match the stored assignment and current
  bound relay. Closing commands always address the captured relay ID.

  During upgrades, multiple unexpired legacy sessions can exist for one profile.
  New admissions fail until those sessions close or expire. Already authenticated
  active sessions may continue heartbeating without adoption in that case; this
  exception disappears as soon as only one live session remains. It never grants
  a recorder or another consumer an ownership handle.
  """

  alias ServiceRadar.Camera.ConsumerLease
  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.RelaySession

  require Ash.Query

  @ttl_ms 30_000

  def reserve_open(source, profile_id, attrs, opts) do
    IngestOwnership.with_source_profile(
      source.id,
      profile_id,
      fn owner ->
        with {:ok, sessions} <- live_sessions(owner, opts),
             {:ok, selected} <- select_relay(owner, sessions),
             :ok <-
               assignment_matches(selected, source.assigned_agent_id, source.assigned_gateway_id) do
          reserve(owner, selected, attrs, opts)
        end
      end,
      opts
    )
  end

  def with_session(session_id, fun, opts) when is_function(fun, 2) do
    read_opts = Keyword.put(opts, :not_found_error?, false)

    case RelaySession.get_by_id(session_id, read_opts) do
      {:ok, %RelaySession{} = initial} ->
        IngestOwnership.with_source_profile(
          initial.camera_source_id,
          initial.stream_profile_id,
          fn owner ->
            case RelaySession.get_by_id(session_id, read_opts) do
              {:ok, %RelaySession{} = session} -> fun.(owner, session)
              {:ok, nil} -> {:error, :not_found}
              {:error, _} = error -> error
            end
          end,
          opts
        )

      {:ok, nil} ->
        {:error, :not_found}

      {:error, _} = error ->
        error
    end
  end

  @doc "Adopts only an unambiguous relay; called while holding the profile lock."
  def adopt(owner, session, opts) do
    cond do
      owner.state == :closing and live?(owner) ->
        {:error, :ownership_lost}

      owner.state == :active and live?(owner) ->
        if owner.relay_session_id == session.id,
          do: {:ok, owner},
          else: {:error, :ownership_lost}

      owner.relay_session_id not in [nil, session.id] ->
        {:error, :ownership_lost}

      true ->
        with {:ok, sessions} <- live_sessions(owner, opts),
             :ok <- no_other_live_session(sessions, session.id) do
          claim_and_bind(owner, session, opts)
        end
    end
  end

  def renew(owner, opts), do: IngestOwnership.renew(owner, @ttl_ms, opts)

  def sync_viewers(owner, attrs, opts) do
    with :ok <- release_viewer(owner, Map.get(attrs, :released_viewer_id), opts) do
      IngestOwnership.acquire_consumers(
        owner,
        :viewer,
        Map.get(attrs, :viewer_ids, []),
        @ttl_ms,
        opts
      )
    end
  end

  def retire_bound(owner, session, opts) do
    if owner.relay_session_id == session.id and owner.state != :released,
      do: IngestOwnership.retire(owner, opts),
      else: {:ok, owner}
  end

  def current?(owner, session),
    do: owner.relay_session_id == session.id and owner.state == :active and live?(owner)

  defp reserve(owner, nil, attrs, opts) do
    with {:ok, lease} <- claim(owner, opts),
         {:ok, session} <-
           RelaySession.create_session(
             Map.put(attrs, :lease_expires_at, lease.lease_expires_at),
             opts
           ),
         {:ok, session} <-
           RelaySession.mark_opening(
             session,
             %{
               command_id: Ecto.UUID.generate(),
               lease_token: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
               lease_expires_at: lease.lease_expires_at
             },
             opts
           ),
         {:ok, _bound} <- IngestOwnership.bind_relay(lease, session.id, opts) do
      {:ok, {:new, session}}
    end
  end

  defp reserve(owner, session, _attrs, opts) do
    result =
      if current?(owner, session), do: {:ok, owner}, else: claim_and_bind(owner, session, opts)

    with {:ok, _lease} <- result, do: {:ok, {:reuse, session}}
  end

  defp select_relay(owner, sessions) do
    cond do
      owner.state == :closing and live?(owner) -> {:error, :relay_closing}
      owner.state == :active and live?(owner) -> select_bound(owner, sessions)
      length(sessions) > 1 -> {:error, :ambiguous_live_relays}
      true -> {:ok, List.first(sessions)}
    end
  end

  defp select_bound(owner, sessions) do
    case Enum.find(sessions, &(&1.id == owner.relay_session_id)) do
      nil -> {:error, :relay_unavailable}
      session -> {:ok, session}
    end
  end

  defp live_sessions(owner, opts) do
    query =
      RelaySession
      |> Ash.Query.filter(
        camera_source_id == ^owner.camera_source_id and
          stream_profile_id == ^owner.stream_profile_id and
          status in [:requested, :opening, :active] and lease_expires_at > ^owner.database_now
      )
      |> Ash.Query.load(:termination_kind)
      |> Ash.Query.limit(2)

    query =
      if owner.state == :active and live?(owner) and not is_nil(owner.relay_session_id),
        do: Ash.Query.filter(query, id == ^owner.relay_session_id),
        else: query

    Ash.read(query, opts)
  end

  defp no_other_live_session(sessions, id) do
    if Enum.any?(sessions, &(&1.id != id)), do: {:error, :ambiguous_live_relays}, else: :ok
  end

  defp assignment_matches(nil, _agent, _gateway), do: :ok
  defp assignment_matches(%{agent_id: agent, gateway_id: gateway}, agent, gateway), do: :ok
  defp assignment_matches(_session, _agent, _gateway), do: {:error, :relay_assignment_changed}

  defp claim_and_bind(owner, session, opts) do
    with {:ok, lease} <- claim(owner, opts),
         do: IngestOwnership.bind_relay(lease, session.id, opts)
  end

  defp claim(owner, opts) do
    IngestOwnership.acquire(
      owner.camera_source_id,
      owner.stream_profile_id,
      Ecto.UUID.generate(),
      @ttl_ms,
      opts
    )
  end

  defp release_viewer(_owner, nil, _opts), do: :ok

  defp release_viewer(owner, key, opts) do
    ConsumerLease
    |> Ash.Query.filter(
      ingest_owner_id == ^owner.id and owner_epoch == ^owner.epoch and kind == :viewer and
        consumer_key == ^key
    )
    |> Ash.read_one(opts)
    |> case do
      {:ok, nil} -> :ok
      {:ok, consumer} -> IngestOwnership.release_consumer(owner, consumer.id, opts)
      {:error, _} = error -> error
    end
  end

  defp live?(%{lease_expires_at: %DateTime{} = expiry, database_now: now}),
    do: DateTime.after?(expiry, now)

  defp live?(_owner), do: false
end
