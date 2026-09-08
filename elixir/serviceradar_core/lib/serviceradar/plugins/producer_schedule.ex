defmodule ServiceRadar.Plugins.ProducerSchedule do
  @moduledoc """
  Operator-owned schedule state for package-declared producer contracts.

  A package declares what can be scheduled. This resource stores an operator's
  enabled/cadence/settings choices and lets AshOban dispatch due work through the
  agent commandbus.
  """

  use Ash.Resource,
    domain: ServiceRadar.Plugins,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  alias Oban.Cron.Expression
  alias ServiceRadar.Plugins.ProducerScheduleDispatcher
  alias ServiceRadar.Policies.Checks.ActorHasPermission
  alias ServiceRadar.Policies.Checks.ActorIsNil

  @operator_fields [
    :enabled,
    :schedule_type,
    :cadence_seconds,
    :cron_expression,
    :timezone,
    :target_query,
    :params,
    :credential_refs,
    :next_due_at,
    :metadata
  ]

  # Attributes that decide *when* a schedule fires. Changing any of them
  # invalidates a pending next_due_at, so it has to be recomputed instead of
  # letting the schedule run once more on its previous cadence first.
  @schedule_shape_fields [
    :enabled,
    :schedule_type,
    :cadence_seconds,
    :cron_expression,
    :timezone
  ]

  postgres do
    table "producer_schedules"
    repo ServiceRadar.Repo
    schema "platform"
  end

  oban do
    triggers do
      trigger :dispatch_due_producer_schedules do
        queue :integrations
        extra_args &ServiceRadar.Oban.AshObanQueueResolver.job_meta/1
        read_action :due_for_dispatch
        scheduler_cron "* * * * *"
        action :dispatch_due

        scheduler_module_name ServiceRadar.Plugins.ProducerSchedule.DispatchDueScheduler
        worker_module_name ServiceRadar.Plugins.ProducerSchedule.DispatchDueWorker
      end
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_due_for_dispatch, action: :due_for_dispatch
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :for_plugin_package do
      argument :plugin_package_id, :uuid, allow_nil?: false
      filter expr(producer_kind == :wasm_plugin and plugin_package_id == ^arg(:plugin_package_id))
    end

    read :for_addon_package do
      argument :addon_package_id, :uuid, allow_nil?: false
      filter expr(producer_kind == :native_addon and addon_package_id == ^arg(:addon_package_id))
    end

    read :due_for_dispatch do
      filter expr(
               enabled == true and
                 schedule_type != :manual and
                 not is_nil(next_due_at) and
                 next_due_at <= now()
             )

      pagination keyset?: true, default_limit: 50
    end

    create :create do
      accept [
        :producer_kind,
        :plugin_package_id,
        :addon_package_id,
        :plugin_assignment_id,
        :addon_assignment_id,
        :schedule_id,
        :display_name,
        :description,
        :contract | @operator_fields
      ]

      validate &validate_schedule/2
      change &set_next_due/2
    end

    update :update do
      require_atomic? false

      accept @operator_fields ++
               [
                 :plugin_assignment_id,
                 :addon_assignment_id,
                 :display_name,
                 :description,
                 :contract
               ]

      validate &validate_schedule/2
      change &set_next_due/2
    end

    update :dispatch_due do
      description "Dispatch a due producer schedule through the agent commandbus"
      require_atomic? false

      change &dispatch_and_record/2
    end

    update :run_now do
      description "Dispatch a producer schedule immediately from settings UI"
      require_atomic? false

      change &dispatch_and_record/2
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    bypass action(:due_for_dispatch) do
      authorize_if ActorIsNil
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:create, :update, :destroy, :run_now]) do
      authorize_if {ActorHasPermission, permission: "settings.plugins.manage"}
      authorize_if {ActorHasPermission, permission: "settings.integrations.manage"}
    end

    policy action(:dispatch_due) do
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if ActorIsNil
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :producer_kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:wasm_plugin, :native_addon]
    end

    attribute :plugin_package_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :addon_package_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :plugin_assignment_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :addon_assignment_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :schedule_id, :string do
      allow_nil? false
      public? true
    end

    attribute :display_name, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      allow_nil? true
      public? true
    end

    attribute :contract, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :schedule_type, :atom do
      allow_nil? false
      public? true
      default :interval
      constraints one_of: [:interval, :cron, :manual]
    end

    attribute :cadence_seconds, :integer do
      allow_nil? false
      public? true
      default 86_400
    end

    attribute :cron_expression, :string do
      allow_nil? true
      public? true
    end

    attribute :timezone, :string do
      allow_nil? false
      public? true
      default "Etc/UTC"
    end

    attribute :target_query, :string do
      allow_nil? true
      public? true
    end

    attribute :params, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :credential_refs, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :last_run_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :next_due_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :last_command_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :last_status, :string do
      allow_nil? false
      public? true
      default "never"
    end

    attribute :last_error, :string do
      allow_nil? true
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :plugin_package, ServiceRadar.Plugins.PluginPackage do
      allow_nil? true
      public? true
      destination_attribute :id
      source_attribute :plugin_package_id
      define_attribute? false
    end

    belongs_to :addon_package, ServiceRadar.Plugins.AddonPackage do
      allow_nil? true
      public? true
      destination_attribute :id
      source_attribute :addon_package_id
      define_attribute? false
    end

    belongs_to :plugin_assignment, ServiceRadar.Plugins.PluginAssignment do
      allow_nil? true
      public? true
      destination_attribute :id
      source_attribute :plugin_assignment_id
      define_attribute? false
    end

    belongs_to :addon_assignment, ServiceRadar.Plugins.AddonAssignment do
      allow_nil? true
      public? true
      destination_attribute :id
      source_attribute :addon_assignment_id
      define_attribute? false
    end
  end

  identities do
    identity :unique_plugin_package_schedule, [:plugin_package_id, :schedule_id]
    identity :unique_addon_package_schedule, [:addon_package_id, :schedule_id]
  end

  defp validate_schedule(changeset, _context) do
    schedule_type = Ash.Changeset.get_attribute(changeset, :schedule_type)
    cadence_seconds = Ash.Changeset.get_attribute(changeset, :cadence_seconds)
    cron_expression = Ash.Changeset.get_attribute(changeset, :cron_expression)
    contract = Ash.Changeset.get_attribute(changeset, :contract) || %{}

    min_cadence = contract_int(contract, "min_cadence_seconds", 1)
    max_cadence = contract_int(contract, "max_cadence_seconds", 31_536_000)

    cond do
      schedule_type == :interval and (is_nil(cadence_seconds) or cadence_seconds <= 0) ->
        {:error, field: :cadence_seconds, message: "must be positive for interval schedules"}

      schedule_type == :interval and
          (cadence_seconds < min_cadence or cadence_seconds > max_cadence) ->
        {:error,
         field: :cadence_seconds, message: "must be within package-declared cadence bounds"}

      schedule_type == :cron and blank?(cron_expression) ->
        {:error, field: :cron_expression, message: "is required for cron schedules"}

      schedule_type == :cron and invalid_cron?(cron_expression) ->
        {:error, field: :cron_expression, message: "is not a valid cron expression"}

      true ->
        :ok
    end
  end

  defp set_next_due(changeset, _context) do
    enabled = Ash.Changeset.get_attribute(changeset, :enabled)
    next_due_at = Ash.Changeset.get_attribute(changeset, :next_due_at)

    cond do
      # Disabled schedules are never dispatched (`:due_for_dispatch` filters on
      # enabled), so leave their next_due_at as-is; re-enabling recomputes it.
      enabled != true ->
        changeset

      is_nil(next_due_at) ->
        Ash.Changeset.change_attribute(changeset, :next_due_at, compute_next_due(changeset))

      # An explicit next_due_at in this same changeset is the caller's own
      # decision (operator-picked run time, dispatch bookkeeping) — honour it
      # rather than overwriting it with a recomputed value.
      Ash.Changeset.changing_attribute?(changeset, :next_due_at) ->
        changeset

      # A cadence / cron / re-enable change has to take effect now. Without
      # this the schedule keeps its previously computed next_due_at and goes on
      # firing at the old cadence until that stale timestamp happens to elapse.
      schedule_shape_changing?(changeset) ->
        Ash.Changeset.change_attribute(changeset, :next_due_at, compute_next_due(changeset))

      true ->
        changeset
    end
  end

  defp schedule_shape_changing?(changeset) do
    Enum.any?(@schedule_shape_fields, &Ash.Changeset.changing_attribute?(changeset, &1))
  end

  defp dispatch_and_record(changeset, _context) do
    schedule = changeset.data
    now = DateTime.utc_now()

    changeset =
      changeset
      |> Ash.Changeset.change_attribute(:last_run_at, now)
      |> Ash.Changeset.change_attribute(:next_due_at, next_due(schedule, now))

    case ProducerScheduleDispatcher.dispatch(schedule) do
      {:ok, command_id} ->
        changeset
        |> Ash.Changeset.change_attribute(:last_command_id, command_id)
        |> Ash.Changeset.change_attribute(:last_status, "dispatched")
        |> Ash.Changeset.change_attribute(:last_error, nil)

      {:error, reason} ->
        changeset
        |> Ash.Changeset.change_attribute(:last_status, "failed")
        |> Ash.Changeset.change_attribute(:last_error, inspect(reason))
    end
  end

  # Interval schedules are re-anchored on the last real run rather than on
  # `now`: an operator who lowers the cadence of a schedule that just ran gets
  # `last_run_at + new cadence`, which is still in the future, so the edit can
  # never trigger an immediate duplicate fire. A schedule that is genuinely
  # overdue under the new cadence becomes due right away instead of waiting one
  # more full cadence, and the floor at `now` keeps the recomputed value out of
  # the past. Cron schedules ignore last_run_at entirely — cron is wall-clock
  # anchored, so the next occurrence is always computed from `now`.
  defp compute_next_due(changeset) do
    now = DateTime.utc_now()

    schedule = %{
      schedule_type: Ash.Changeset.get_attribute(changeset, :schedule_type),
      cadence_seconds: Ash.Changeset.get_attribute(changeset, :cadence_seconds),
      cron_expression: Ash.Changeset.get_attribute(changeset, :cron_expression),
      timezone: Ash.Changeset.get_attribute(changeset, :timezone)
    }

    case schedule.schedule_type do
      :interval ->
        schedule
        |> next_due(Ash.Changeset.get_data(changeset, :last_run_at) || now)
        |> not_before(now)

      _other ->
        next_due(schedule, now)
    end
  end

  defp not_before(nil, _now), do: nil

  defp not_before(%DateTime{} = due_at, now) do
    if DateTime.before?(due_at, now), do: now, else: due_at
  end

  defp next_due(%{schedule_type: :manual}, _now), do: nil

  defp next_due(%{schedule_type: :cron, cron_expression: cron, timezone: timezone}, now) do
    next_cron_due(cron, timezone, now) || DateTime.add(now, 86_400, :second)
  end

  defp next_due(%{cadence_seconds: cadence_seconds}, now) do
    DateTime.add(now, cadence_seconds || 86_400, :second)
  end

  defp next_cron_due(cron, timezone, now) when is_binary(cron) do
    with {:ok, expr} <- Expression.parse(cron),
         {:ok, base} <- DateTime.shift_zone(now, normalize_timezone(timezone)),
         %DateTime{} = next_at <- Expression.next_at(expr, base) do
      next_at
    else
      _ -> nil
    end
  end

  defp next_cron_due(_cron, _timezone, _now), do: nil

  defp invalid_cron?(cron) do
    case Expression.parse(cron) do
      {:ok, _expr} -> false
      _ -> true
    end
  end

  defp normalize_timezone(timezone) when timezone in ["UTC", "Etc/UTC"], do: "Etc/UTC"
  defp normalize_timezone(_timezone), do: "Etc/UTC"

  defp contract_int(contract, key, default) do
    case Map.get(contract, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_int(value, default)
      _ -> default
    end
  end

  defp parse_int(value, default) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")
end
