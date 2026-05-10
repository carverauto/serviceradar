defmodule ServiceRadar.Automation.Ansible.IngestorActions do
  @moduledoc """
  Side-effecting operations EventIngestor performs to apply AWX events.

  Lives behind a behaviour so EventIngestor can be unit-tested without a
  live database — production code uses `IngestorAshActions`, tests
  substitute fakes via the `:actions` option on
  `EventIngestor.handle_command_result/2`.
  """

  @type id :: term()
  @type run :: %{required(:id) => id, required(:state) => atom(), required(:last_event_id) => integer(), optional(any()) => any()}
  @type play :: %{required(:id) => id, optional(any()) => any()}
  @type task :: %{required(:id) => id, optional(any()) => any()}
  @type target :: %{required(:id) => id, optional(any()) => any()}

  @callback get_run_by_awx_job_id(awx_job_id :: integer()) :: {:ok, run()} | {:error, term()}

  @callback upsert_play(args :: map()) :: {:ok, play()} | {:error, term()}

  @callback upsert_task(args :: map()) :: {:ok, task()} | {:error, term()}

  @callback upsert_task_result(args :: map()) :: {:ok, map()} | {:error, term()}

  @callback get_run_target(run_id :: id, awx_host_name :: String.t()) ::
              {:ok, target()} | {:error, term()}

  @callback record_target_outcome(target :: target(), args :: map()) ::
              {:ok, target()} | {:error, term()}

  @callback advance_watermark(run :: run(), last_event_id :: integer()) ::
              {:ok, run()} | {:error, term()}

  @callback transition_run(run :: run(), transition :: atom(), args :: map()) ::
              {:ok, run()} | {:error, term()}

  @doc """
  Look up the `context` map on the `AgentCommand` row identified by
  `command_id`. Used by the launch_job / fetch_job / cancel_job / ping
  result handlers to correlate the result back to its originating
  PlaybookRun or AnsibleController.
  """
  @callback get_command_context(command_id :: String.t()) :: {:ok, map()} | {:error, term()}

  @callback get_run_by_id(run_id :: id) :: {:ok, run()} | {:error, term()}

  @callback get_controller_by_id(controller_id :: id) :: {:ok, map()} | {:error, term()}

  @callback record_controller_health(controller :: map(), args :: map()) ::
              {:ok, map()} | {:error, term()}
end
