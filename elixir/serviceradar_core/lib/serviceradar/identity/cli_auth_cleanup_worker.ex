defmodule ServiceRadar.Identity.CliAuthCleanupWorker do
  @moduledoc """
  Daily cleanup for the RFC 8628 CLI device-code flow.

  Three jobs, all running off the same scheduled invocation:

  1. **Expire stale device authorizations** — `:pending` rows whose
     `expires_at` is in the past flip to `:expired`. The token endpoint
     also performs this transition opportunistically when a CLI polls,
     but the worker catches rows nobody polls (the user closed their
     terminal mid-flow).
  2. **Expire stale CLI sessions** — `:active` rows whose
     `expires_at` is in the past flip to `:expired`. The Settings UI
     hides those rows from the active list automatically.
  3. **Hard-delete old terminal rows** — `device_authorizations` in
     `:expired`/`:denied`/`:approved` *and* `cli_sessions` in
     `:revoked`/`:expired` whose `inserted_at` is older than the
     retention window (default 90 days) get destroyed. The Settings UI
     stops surfacing them well before this since it filters on
     `expires_at`; this step keeps the table from growing unbounded.

  Reschedules itself to run again 24 hours later. The `unique`
  constraint on the worker prevents double-scheduling.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ash.Expr

  alias Ash.Page.Keyset
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.CliSession
  alias ServiceRadar.Identity.DeviceAuthorization
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  @default_retention_days 90
  @default_reschedule_seconds 86_400

  @doc """
  Schedules the cleanup if not already scheduled. Idempotent.
  """
  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if existing_job?() do
        {:ok, :already_scheduled}
      else
        %{} |> new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    retention_days = Keyword.get(config, :retention_days, @default_retention_days)
    retention_cutoff = DateTime.add(now, -retention_days * 86_400, :second)

    expire_pending_device_authorizations(now)
    expire_active_cli_sessions(now)
    delete_old_device_authorizations(retention_cutoff)
    delete_old_cli_sessions(retention_cutoff)
    schedule_next()

    :ok
  end

  defp schedule_next do
    ObanSupport.safe_insert(
      SelfScheduling.successor_changeset(__MODULE__, %{}, @default_reschedule_seconds)
    )

    :ok
  end

  defp existing_job? do
    import Ecto.Query, only: [from: 2]

    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    ServiceRadar.Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  ## Pending device authorizations -> :expired

  defp expire_pending_device_authorizations(now) do
    actor = SystemActor.system(:cli_auth_cleanup)

    query =
      Ash.Query.filter(
        DeviceAuthorization,
        expr(status == :pending and expires_at <= ^now)
      )

    case Ash.read(query, actor: actor) do
      {:ok, %Keyset{results: rows}} -> Enum.each(rows, &expire_device(&1, actor))
      {:ok, rows} when is_list(rows) -> Enum.each(rows, &expire_device(&1, actor))
      {:error, reason} -> log_warning("read pending device authorizations", reason)
    end
  end

  defp expire_device(row, actor) do
    case DeviceAuthorization.expire(row, actor: actor) do
      {:ok, _} -> :ok
      {:error, reason} -> log_warning("expire device authorization #{row.id}", reason)
    end
  end

  ## Active CLI sessions -> :expired

  defp expire_active_cli_sessions(now) do
    actor = SystemActor.system(:cli_auth_cleanup)

    query =
      Ash.Query.filter(
        CliSession,
        expr(status == :active and expires_at <= ^now)
      )

    case Ash.read(query, actor: actor) do
      {:ok, %Keyset{results: rows}} -> Enum.each(rows, &expire_session(&1, actor))
      {:ok, rows} when is_list(rows) -> Enum.each(rows, &expire_session(&1, actor))
      {:error, reason} -> log_warning("read active CLI sessions", reason)
    end
  end

  defp expire_session(row, actor) do
    case CliSession.mark_expired(row, actor: actor) do
      {:ok, _} -> :ok
      {:error, reason} -> log_warning("expire CLI session #{row.jti}", reason)
    end
  end

  ## Hard-delete old terminal rows

  defp delete_old_device_authorizations(cutoff) do
    actor = SystemActor.system(:cli_auth_cleanup)

    query =
      Ash.Query.filter(
        DeviceAuthorization,
        expr(status in [:expired, :denied, :approved] and inserted_at < ^cutoff)
      )

    case Ash.read(query, actor: actor) do
      {:ok, %Keyset{results: rows}} ->
        Enum.each(rows, &destroy_row(&1, actor, "device_authorization"))

      {:ok, rows} when is_list(rows) ->
        Enum.each(rows, &destroy_row(&1, actor, "device_authorization"))

      {:error, reason} ->
        log_warning("read old device authorizations", reason)
    end
  end

  defp delete_old_cli_sessions(cutoff) do
    actor = SystemActor.system(:cli_auth_cleanup)

    query =
      Ash.Query.filter(
        CliSession,
        expr(status in [:revoked, :expired] and inserted_at < ^cutoff)
      )

    case Ash.read(query, actor: actor) do
      {:ok, %Keyset{results: rows}} -> Enum.each(rows, &destroy_row(&1, actor, "cli_session"))
      {:ok, rows} when is_list(rows) -> Enum.each(rows, &destroy_row(&1, actor, "cli_session"))
      {:error, reason} -> log_warning("read old CLI sessions", reason)
    end
  end

  defp destroy_row(row, actor, label) do
    case Ash.destroy(row, actor: actor) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> log_warning("destroy #{label} #{inspect(row)}", reason)
    end
  end

  defp log_warning(label, reason) do
    Logger.warning("CliAuthCleanupWorker: #{label}", reason: inspect(reason))
  end
end
