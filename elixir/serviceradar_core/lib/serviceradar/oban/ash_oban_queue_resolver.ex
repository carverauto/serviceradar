defmodule ServiceRadar.Oban.AshObanQueueResolver do
  @moduledoc """
  Queue resolver for AshOban that routes jobs to the appropriate queue.

  ## Usage in Ash Resources

      defmodule MyResource do
        use Ash.Resource,
          extensions: [AshOban]

        oban do
          triggers do
            trigger :my_action do
              queue {:mfa, {ServiceRadar.Oban.AshObanQueueResolver, :resolve, [:integrations]}}
              worker MyWorker
            end
          end
        end
      end

  ## Queue Types

  - `:service_checks` - Service check polling jobs
  - `:alerts` - Alert processing jobs
  - `:notifications` - Alert notification jobs
  - `:onboarding` - Edge onboarding jobs
  - `:events` - Event processing jobs
  - `:integrations` - Integration sync jobs
  - `:edge` - Edge management jobs
  - `:sweeps` - Sweep processing jobs
  - `:default` - General purpose jobs
  """

  @doc """
  Resolves the queue name for an AshOban trigger.

  Called by AshOban with the record and queue_type.

  ## Parameters

    - `_record` - The Ash resource record triggering the job (unused)
    - `queue_type` - The queue type atom (:service_checks, :alerts, :notifications, etc.)

  ## Returns

  The queue name atom (e.g., `:alerts`)
  """
  @spec resolve(Ash.Resource.record(), atom()) :: atom()
  def resolve(_record, queue_type \\ :default) do
    queue_type
  end

  @doc """
  Returns extra job arguments for AshOban triggers.

  Used in AshOban trigger configuration. Returns an empty map
  as no additional job metadata is needed.

  ## Example

      oban do
        triggers do
          trigger :process do
            worker MyWorker
            on_insert? true
            extra_args &AshObanQueueResolver.job_meta/1
          end
        end
      end
  """
  @spec job_meta(Ash.Resource.record()) :: map()
  def job_meta(_record), do: %{}

  @doc """
  Creates a queue resolver function for a specific queue type.

  Returns an MFA tuple suitable for AshOban configuration.

  ## Example

      oban do
        triggers do
          trigger :sync_config do
            queue AshObanQueueResolver.queue_for(:sync)
          end
        end
      end
  """
  @spec queue_for(atom()) :: {:mfa, {module(), atom(), [atom()]}}
  def queue_for(queue_type) when is_atom(queue_type) do
    {:mfa, {__MODULE__, :resolve, [queue_type]}}
  end
end
