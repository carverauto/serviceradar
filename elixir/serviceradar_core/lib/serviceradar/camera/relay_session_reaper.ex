defmodule ServiceRadar.Camera.RelaySessionReaper do
  @moduledoc """
  Closes persisted camera relay sessions whose edge pull is no longer live.

  Sessions are closed by media-plane events: the gateway and core-elx trackers
  report activation, heartbeats and closes to `RelaySessionLifecycle`. When the
  media plane stops without reporting -- a gateway or core-elx restart drops its
  in-memory tracker, and the gateway's own lease sweep only emits telemetry --
  the row stays `requested`, `opening`, `active` or `closing` forever. Reuse
  already ignores such rows, so every stuck row is permanent clutter that the
  relay capacity views and session counts still read.

  A live pull renews `lease_expires_at` on every heartbeat, roughly every ten
  seconds with a thirty-second lease. A lease that lapsed more than `grace`
  ago therefore cannot belong to a live pull, and the session is closed with
  the reason `"relay lease expired"`. A `closing` session keeps the close reason
  it already carries. Rows that never received a lease are judged by age.

  Each close carries a compare-and-set filter, so a session renewed between the
  read and the update is left alone.
  """

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.RelaySession

  require Logger

  @actor_component :camera_relay_session_reaper
  @default_lease_grace_seconds 120
  @default_unleased_grace_seconds 600
  @default_batch_size 200
  @lease_expired_reason "relay lease expired"

  @type result :: %{
          closed: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer()
        }

  @spec reap(keyword()) :: {:ok, result()} | {:error, term()}
  def reap(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    lease_cutoff =
      DateTime.shift(now,
        second: -Keyword.get(opts, :lease_grace_seconds, @default_lease_grace_seconds)
      )

    unleased_cutoff =
      DateTime.shift(
        now,
        second: -Keyword.get(opts, :unleased_grace_seconds, @default_unleased_grace_seconds)
      )

    actor = Keyword.get(opts, :actor, SystemActor.system(@actor_component))
    lister = Keyword.get(opts, :lister, &list_stale/4)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    with {:ok, sessions} <- lister.(lease_cutoff, unleased_cutoff, batch_size, actor) do
      result =
        Enum.reduce(sessions, %{closed: 0, skipped: 0, failed: 0}, fn session, acc ->
          session
          |> close_stale(close_attrs(session), lease_cutoff, actor)
          |> tally(session, acc)
        end)

      {:ok, result}
    end
  end

  defp close_attrs(%{status: :closing}), do: %{viewer_count: 0}
  defp close_attrs(_session), do: %{close_reason: @lease_expired_reason, viewer_count: 0}

  defp tally({:ok, _session}, _session_in, acc), do: Map.update!(acc, :closed, &(&1 + 1))
  defp tally({:skip, _reason}, _session, acc), do: Map.update!(acc, :skipped, &(&1 + 1))

  defp tally({:error, reason}, session, acc) do
    Logger.warning("Camera relay session reaper failed to close session",
      relay_session_id: Map.get(session, :id),
      reason: inspect(reason)
    )

    Map.update!(acc, :failed, &(&1 + 1))
  end

  defp list_stale(lease_cutoff, unleased_cutoff, batch_size, actor) do
    RelaySession.list_stale_for_reap(lease_cutoff, unleased_cutoff,
      actor: actor,
      query: [limit: batch_size]
    )
  end

  defp close_stale(session, attrs, lease_cutoff, actor) do
    status = session.status

    session
    |> Ash.Changeset.for_update(:mark_closed, attrs, actor: actor)
    |> Ash.Changeset.filter(
      expr(status == ^status and (is_nil(lease_expires_at) or lease_expires_at < ^lease_cutoff))
    )
    |> Ash.update()
    |> case do
      {:ok, updated} ->
        {:ok, updated}

      {:error, %Ash.Error.Invalid{errors: errors} = error} ->
        if Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)),
          do: {:skip, :renewed_or_changed},
          else: {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
