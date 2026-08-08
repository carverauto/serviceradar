defmodule ServiceRadar.Automation.Ansible.AwxCatalogSyncWorker do
  @moduledoc """
  Per-controller catalog sync.

  Periodically dispatches `awx.list_templates` for each registered
  AnsibleController. The result handler in `EventIngestor` upserts one
  `Playbook` row per AWX Job Template with `source_type: :awx`.

  Survey specs (the per-template variable prompts) are NOT fetched eagerly
  by this worker -- AWX exposes them on a sub-resource and pre-fetching
  every template's survey adds N extra round-trips. Instead the launch
  UI dispatches `awx.fetch_template` lazily when an operator picks a
  playbook to run. If on-demand survey fetching ever proves too slow we
  can flip the strategy without changing the data model.

  Cadence: `controller.catalog_sync_interval_seconds` (default 600s, set
  per-controller). See openspec change `add-ansible-integration` task 3.4.
  """

  use Oban.Worker,
    queue: :ansible_catalog,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_interval_seconds 600
  @min_interval_seconds 60

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
    actor = SystemActor.system(:awx_catalog_sync_worker)

    case Controller.get_by_id(controller_id, actor: actor) do
      {:ok, %Controller{enabled: false}} ->
        # Controller paused -- end the chain (re-enabling re-seeds it).
        :ok

      {:ok, controller} ->
        _ = sync(controller)
        schedule_next(controller)
        :ok

      {:error, _reason} ->
        # Controller deleted -- end the chain.
        :ok
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("AWX AwxCatalogSyncWorker: invalid args", args: inspect(args))
    {:error, :invalid_args}
  end

  @doc """
  Dispatch one `awx.list_templates` for the given controller. Exposed for
  unit tests; production calls this from `perform/1`.

  Options:
    * `:awx_client` (default `AwxClient`).
  """
  @spec sync(Controller.t(), keyword()) :: :ok | {:error, term()}
  def sync(%Controller{} = controller, opts \\ []) do
    awx_client = Keyword.get(opts, :awx_client, AwxClient)

    case awx_client.list_templates(controller,
           source: :automation,
           context: %{
             "controller_id" => controller.id,
             "verb" => "awx.list_templates"
           }
         ) do
      {:ok, _command} ->
        :ok

      {:error, reason} = err ->
        Logger.warning("AWX AwxCatalogSyncWorker: dispatch failed",
          controller_id: controller.id,
          reason: inspect(reason)
        )

        err
    end
  end

  ## Internals -----------------------------------------------------------------

  defp schedule_next(%Controller{} = controller) do
    seconds = interval_seconds(controller)

    _ =
      __MODULE__
      |> SelfScheduling.successor_changeset(%{"controller_id" => controller.id}, seconds)
      |> ObanSupport.safe_insert()

    :ok
  end

  defp interval_seconds(%Controller{catalog_sync_interval_seconds: s})
       when is_integer(s) and s > 0 do
    max(@min_interval_seconds, s)
  end

  defp interval_seconds(_), do: @default_interval_seconds

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
