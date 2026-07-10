defmodule ServiceRadar.Automation.Northbound.PollWorker do
  @moduledoc """
  Oban worker that resumes deferred northbound action targets.
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 3,
    unique: [
      period: 60,
      fields: [:worker, :args],
      keys: [:target_id],
      states: :incomplete
    ]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Northbound.ActionInvocation
  alias ServiceRadar.Automation.Northbound.ActionInvocationTarget
  alias ServiceRadar.Automation.Northbound.Dispatcher
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @spec schedule_target(ActionInvocationTarget.t() | map(), DateTime.t() | nil) ::
          {:ok, Oban.Job.t()} | {:ok, :not_scheduled} | {:error, term()}
  def schedule_target(%{id: target_id}, %DateTime{} = next_poll_at) when is_binary(target_id) do
    schedule_in =
      next_poll_at
      |> DateTime.diff(DateTime.utc_now(), :second)
      |> max(0)

    %{"target_id" => target_id}
    |> new(schedule_in: schedule_in)
    |> ObanSupport.safe_insert()
  end

  def schedule_target(_target, _next_poll_at), do: {:ok, :not_scheduled}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"target_id" => target_id}}) do
    actor = SystemActor.system(:northbound_poll_worker)

    with {:ok, target} <- ActionInvocationTarget.get_by_id(target_id, actor: actor),
         :ok <- ensure_not_canceled(target, actor),
         :ok <- ensure_not_expired(target, actor) do
      case Dispatcher.dispatch_poll(target, system_actor: actor) do
        {:ok, _target} ->
          :ok

        {:error, {:not_pollable, _status}} ->
          :ok

        {:error, reason} ->
          Logger.warning("Northbound poll dispatch failed",
            target_id: target_id,
            reason: inspect(reason)
          )

          {:error, reason}
      end
    else
      {:ok, nil} ->
        :ok

      {:error, :expired} ->
        :ok

      {:error, :canceled} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("Northbound PollWorker: invalid args", args: inspect(args))
    {:error, :invalid_args}
  end

  defp ensure_not_canceled(%ActionInvocationTarget{invocation_id: nil}, _actor), do: :ok

  defp ensure_not_canceled(%ActionInvocationTarget{invocation_id: invocation_id} = target, actor) do
    case ActionInvocation.get_by_id(invocation_id, actor: actor) do
      {:ok, %ActionInvocation{state: :canceled}} ->
        _ =
          ActionInvocationTarget.record_canceled(
            target,
            %{result: %{"status" => "canceled", "message" => "Northbound action was canceled"}},
            actor: actor
          )

        {:error, :canceled}

      _ ->
        :ok
    end
  end

  defp ensure_not_expired(%ActionInvocationTarget{poll_deadline_at: nil}, _actor), do: :ok

  defp ensure_not_expired(%ActionInvocationTarget{poll_deadline_at: deadline} = target, actor) do
    if DateTime.before?(deadline, DateTime.utc_now()) do
      _ =
        ActionInvocationTarget.record_expired(
          target,
          %{
            result: %{
              "status" => "expired",
              "message" => "Deferred northbound action exceeded its polling deadline"
            }
          },
          actor: actor
        )

      _ = expire_invocation_if_terminal(target.invocation_id, actor)

      {:error, :expired}
    else
      :ok
    end
  end

  defp ensure_not_expired(_target, _actor), do: :ok

  defp expire_invocation_if_terminal(nil, _actor), do: :ok

  defp expire_invocation_if_terminal(invocation_id, actor) do
    with {:ok, targets} <- ActionInvocationTarget.list_for_invocation(invocation_id, actor: actor),
         true <- Enum.all?(targets, &terminal_status?/1),
         {:ok, invocation} <- ActionInvocation.get_by_id(invocation_id, actor: actor) do
      ActionInvocation.record_expired(
        invocation,
        %{
          result_summary: %{
            "status" => "expired",
            "message" => "Deferred northbound action exceeded its polling deadline"
          },
          error_class: "provider_timeout",
          error_message: "Deferred northbound action exceeded its polling deadline"
        },
        actor: actor
      )
    else
      _ -> :ok
    end
  end

  defp terminal_status?(%ActionInvocationTarget{status: status})
       when status in [:succeeded, :failed, :skipped, :suppressed, :expired, :canceled], do: true

  defp terminal_status?(_target), do: false
end
