defmodule ServiceRadar.Jobs.JobSchedule do
  @moduledoc """
  Background job schedule resource for managing recurring job configurations.

  JobSchedules define when background jobs should be executed via cron expressions.
  They integrate with Oban for job execution and support dynamic configuration
  updates without requiring application restart.

  ## Fields

  - `:job_key` - Unique identifier for the job type
  - `:cron` - Cron expression defining execution schedule
  - `:timezone` - Timezone for cron evaluation (default: Etc/UTC)
  - `:args` - JSON arguments passed to the job worker
  - `:enabled` - Whether the schedule is active
  - `:unique_period_seconds` - Uniqueness constraint period
  - `:last_enqueued_at` - When the job was last enqueued

  ## Cron Expression Validation

  Cron expressions are validated using Oban's cron parser to ensure
  they are syntactically correct before being saved.
  """

  use Ash.Resource,
    domain: ServiceRadar.Jobs,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "ng_job_schedules"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :context
  end

  code_interface do
    define :get_by_job_key, action: :by_job_key, args: [:job_key]
    define :list_enabled, action: :enabled
  end

  actions do
    defaults [:read]

    read :by_job_key do
      argument :job_key, :string, allow_nil?: false
      get? true
      filter expr(job_key == ^arg(:job_key))
    end

    read :enabled do
      description "All enabled schedules"
      filter expr(enabled == true)
    end

    create :create do
      accept [:job_key, :cron, :timezone, :args, :enabled, :unique_period_seconds]

      validate fn changeset, _context ->
        cron = Ash.Changeset.get_attribute(changeset, :cron)
        validate_cron_expression(cron)
      end
    end

    update :update do
      accept [:cron, :timezone, :args, :enabled, :unique_period_seconds]
      require_atomic? false

      validate fn changeset, _context ->
        cron = Ash.Changeset.get_attribute(changeset, :cron)

        if cron do
          validate_cron_expression(cron)
        else
          :ok
        end
      end
    end

    update :enable do
      change set_attribute(:enabled, true)
    end

    update :disable do
      change set_attribute(:enabled, false)
    end

    update :update_last_enqueued do
      description "Update the last_enqueued_at timestamp"
      accept [:last_enqueued_at]
    end
  end

  policies do
    # Allow all authenticated users to read schedules
    policy action_type(:read) do
      authorize_if always()
    end

    # Operators and admins can create and update
    policy action([:create, :update, :enable, :disable, :update_last_enqueued]) do
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :super_admin)
      # Allow system operations (no actor)
      authorize_if always()
    end
  end

  attributes do
    integer_primary_key :id

    attribute :job_key, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100
      description "Unique identifier for the job type"
    end

    attribute :cron, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100
      description "Cron expression for schedule"
    end

    attribute :timezone, :string do
      default "Etc/UTC"
      public? true
      constraints max_length: 50
      description "Timezone for cron evaluation"
    end

    attribute :args, :map do
      default %{}
      public? true
      description "Arguments passed to the job worker"
    end

    attribute :enabled, :boolean do
      default true
      public? true
      description "Whether this schedule is active"
    end

    attribute :unique_period_seconds, :integer do
      public? true
      description "Uniqueness constraint period in seconds"
    end

    attribute :last_enqueued_at, :utc_datetime_usec do
      public? true
      description "When the job was last enqueued"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  calculations do
    calculate :status_label,
              :string,
              expr(
                if enabled do
                  "Enabled"
                else
                  "Disabled"
                end
              )
  end

  identities do
    identity :unique_job_key, [:job_key]
  end

  # Cron expression validation using Oban's parser
  defp validate_cron_expression(nil), do: :ok
  defp validate_cron_expression(""), do: {:error, field: :cron, message: "cannot be empty"}

  defp validate_cron_expression(cron) when is_binary(cron) do
    case Oban.Cron.Expression.parse(cron) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        {:error, field: :cron, message: "invalid cron expression: #{Exception.message(error)}"}
    end
  end
end
