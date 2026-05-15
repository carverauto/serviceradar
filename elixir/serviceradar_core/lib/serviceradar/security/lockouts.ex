defmodule ServiceRadar.Security.Lockouts do
  @moduledoc """
  Cross-IP lockout trigger and operator-facing API for
  `ServiceRadar.Security.AuthLockout`.

  Auth controllers / LiveViews call `record_failed_login/2` after each
  failed credential exchange. The helper:

    1. Emits a `:login_failed` `SecurityEvent` so the audit stream
       reflects the attempt regardless of whether it crosses the
       lockout threshold.
    2. Counts recent `:login_failed` events for the actor over the
       trailing window; if that count exceeds the configured
       threshold and the actor is not already locked, opens a new
       `AuthLockout` row with a default expiration.

  All ServiceRadar.Security.Lockouts functions use the SystemActor so
  background lockout writes are properly authorized.
  """

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Security.AuthLockout
  alias ServiceRadar.Security.Events
  alias ServiceRadar.Security.SecurityEvent

  require Ash.Query

  @default_threshold 20
  @default_window_seconds 3_600
  @default_lock_seconds 3_600

  @doc """
  Records a failed login and triggers a lockout if the actor has
  crossed the configured threshold.

  `actor_id` is the string identifier (typically `to_string(user.id)`)
  that ties failures to a single account across source IPs. `metadata`
  is folded into the SecurityEvent `details`.
  """
  @spec record_failed_login(String.t(), map()) :: :ok | {:locked, AuthLockout.t()}
  def record_failed_login(actor_id, metadata \\ %{}) when is_binary(actor_id) do
    Events.record(%{
      kind: :login_failed,
      severity: :warning,
      actor_id: actor_id,
      ip: Map.get(metadata, :ip),
      route: Map.get(metadata, :route),
      details: Map.drop(metadata, [:ip, :route])
    })

    maybe_trigger_lockout(actor_id, metadata)
  end

  @doc """
  Returns the currently-active lockout for `actor_id`, or nil.
  """
  @spec active_lockout(String.t()) :: AuthLockout.t() | nil
  def active_lockout(actor_id) when is_binary(actor_id) do
    actor = SystemActor.system(:lockouts)

    case AuthLockout.get_active_for(actor_id, actor: actor) do
      {:ok, %AuthLockout{} = row} -> row
      _ -> nil
    end
  end

  @doc """
  Clears (unlocks) `lockout` on behalf of `admin_actor_id`. Records a
  `:lockout_cleared` SecurityEvent. Returns the updated lockout.
  """
  @spec unlock(AuthLockout.t(), String.t(), String.t() | nil) ::
          {:ok, AuthLockout.t()} | {:error, term()}
  def unlock(%AuthLockout{} = lockout, admin_actor_id, reason \\ nil) do
    actor = SystemActor.system(:lockouts)

    result =
      lockout
      |> Ash.Changeset.for_update(:unlock, %{
        cleared_by: admin_actor_id,
        clear_reason: reason
      })
      |> Ash.update(actor: actor)

    case result do
      {:ok, updated} ->
        Events.record(%{
          kind: :lockout_cleared,
          severity: :info,
          actor_id: lockout.actor_id,
          details: %{"cleared_by" => admin_actor_id, "reason" => reason}
        })

        {:ok, updated}

      other ->
        other
    end
  end

  ## Internals

  defp maybe_trigger_lockout(actor_id, metadata) do
    config = config()

    threshold = Keyword.get(config, :threshold, @default_threshold)
    window_seconds = Keyword.get(config, :window_seconds, @default_window_seconds)
    lock_seconds = Keyword.get(config, :lock_seconds, @default_lock_seconds)

    # The Events.record/1 call above is fire-and-forget — the
    # SecurityEvent we just recorded isn't visible to the query below
    # yet. Counting prior persisted events and adding 1 for the
    # current attempt gives the correct trip threshold without
    # waiting on the async recorder.
    if recent_failed_login_count(actor_id, window_seconds) + 1 >= threshold do
      lock_if_not_already_locked(actor_id, lock_seconds, metadata)
    else
      :ok
    end
  end

  defp recent_failed_login_count(actor_id, window_seconds) do
    actor = SystemActor.system(:lockouts)
    cutoff = DateTime.add(DateTime.utc_now(), -window_seconds, :second)

    case SecurityEvent
         |> Ash.Query.filter(
           expr(kind == :login_failed and actor_id == ^actor_id and occurred_at >= ^cutoff)
         )
         |> Ash.count(actor: actor) do
      {:ok, count} -> count
      _ -> 0
    end
  rescue
    # If SecurityEvent storage is unreachable, fall back to not locking
    # rather than crashing the auth flow.
    _ -> 0
  end

  defp lock_if_not_already_locked(actor_id, lock_seconds, metadata) do
    case active_lockout(actor_id) do
      %AuthLockout{} = existing ->
        {:locked, existing}

      nil ->
        actor = SystemActor.system(:lockouts)
        expires_at = DateTime.add(DateTime.utc_now(), lock_seconds, :second)

        result =
          AuthLockout.lock_actor(
            %{
              actor_id: actor_id,
              reason: "cross_ip_failed_login_threshold",
              locked_by: "system",
              expires_at: expires_at
            },
            actor: actor
          )

        case result do
          {:ok, lockout} ->
            Events.record(%{
              kind: :lockout_triggered,
              severity: :critical,
              actor_id: actor_id,
              ip: Map.get(metadata, :ip),
              route: Map.get(metadata, :route),
              details: %{
                "reason" => "cross_ip_failed_login_threshold",
                "expires_at" => DateTime.to_iso8601(expires_at)
              }
            })

            {:locked, lockout}

          {:error, _} ->
            :ok
        end
    end
  end

  defp config do
    Application.get_env(:serviceradar_core, __MODULE__, [])
  end
end
