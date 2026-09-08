defmodule ServiceRadar.Automation.Ansible.ControllerHealthWorker do
  @moduledoc """
  Per-controller health probe.

  Periodically dispatches `awx.ping` for each registered AnsibleController.
  Result handling (updating `Controller.last_health_at` / `:status`) lives
  in `EventIngestor.handle_command_result/2`; this worker is purely
  responsible for keeping the dispatch chain alive.

  See openspec change `add-ansible-integration` -- proposal "Affected
  code" includes `ControllerHealthWorker (AshOban)`. Cadence is operator-
  configurable via the `:awx_controller_health_interval_seconds` app env
  (default 30s).
  """

  use Oban.Worker,
    queue: :ansible_pulse,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_interval_seconds 30
  @min_interval_seconds 5

  @doc """
  Idempotent: schedule a health probe for `controller_id` if one isn't
  already in flight. Call from app startup or after creating a controller.
  """
  @spec ensure_scheduled(String.t()) ::
          {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled(controller_id) when is_binary(controller_id) do
    if scheduled_for?(controller_id) do
      {:ok, :already_scheduled}
    else
      %{"controller_id" => controller_id}
      |> new()
      |> ObanSupport.safe_insert()
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"controller_id" => controller_id}}) do
    actor = SystemActor.system(:awx_controller_health_worker)

    case Controller.get_by_id(controller_id, actor: actor) do
      {:ok, %Controller{enabled: false}} ->
        # Controller paused -- end the chain (re-enabling re-seeds it).
        :ok

      {:ok, controller} ->
        _ = probe(controller)
        schedule_next(controller)
        :ok

      {:error, _reason} ->
        # Controller deleted -- end the chain.
        :ok
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("AWX ControllerHealthWorker: invalid args", args: inspect(args))
    {:error, :invalid_args}
  end

  @doc """
  Dispatch one `awx.ping` for the given controller. Exposed for unit
  tests; production calls this from `perform/1`.

  Options:
    * `:awx_client` (default `AwxClient`).
  """
  @spec probe(Controller.t(), keyword()) :: :ok | {:error, term()}
  def probe(%Controller{} = controller, opts \\ []) do
    awx_client = Keyword.get(opts, :awx_client, AwxClient)

    case awx_client.ping(controller,
           source: :automation,
           context: %{
             "controller_id" => controller.id,
             "verb" => "awx.ping"
           }
         ) do
      {:ok, _command} ->
        :ok

      {:error, reason} = err ->
        Logger.warning("AWX ControllerHealthWorker: dispatch failed",
          controller_id: controller.id,
          reason: inspect(reason)
        )

        err
    end
  end

  ## Internals -----------------------------------------------------------------

  defp schedule_next(%Controller{} = controller) do
    seconds = interval_seconds()

    _ =
      __MODULE__
      |> SelfScheduling.successor_changeset(%{"controller_id" => controller.id}, seconds)
      |> ObanSupport.safe_insert()

    :ok
  end

  defp interval_seconds do
    seconds =
      Application.get_env(
        :serviceradar_core,
        :awx_controller_health_interval_seconds,
        @default_interval_seconds
      )

    max(@min_interval_seconds, seconds)
  end

  defp scheduled_for?(controller_id) do
    import Ecto.Query

    query =
      from job in Oban.Job,
        where:
          job.worker == ^to_string(__MODULE__) and
            fragment("? -> ?", job.args, "controller_id") == ^controller_id and
            job.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1

    ServiceRadar.Repo.exists?(query, prefix: ObanSupport.prefix())
  end
end
