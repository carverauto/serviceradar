defmodule ServiceRadar.Inventory.DeviceHostnameRdnsSettings do
  @moduledoc """
  Deployment-scoped settings for reverse-DNS hostname enrichment of `ocsf_devices`.

  AshOban ticks every minute and runs `:run` when the singleton row is enabled
  and `next_run_at` is due. Operators set enable/cron from Settings.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  alias Oban.Cron.Expression
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.DeviceHostnameRdns
  alias ServiceRadar.Policies.Checks.ActorIsNil
  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLQuery

  require Logger

  @settings_fields [
    :enabled,
    :cron,
    :timezone,
    :srql_query,
    :batch_size,
    :timeout_ms,
    :retry_after_minutes,
    :overwrite_existing
  ]

  @default_cron "0 * * * *"
  @default_srql_query DeviceHostnameRdns.default_srql_query()

  postgres do
    table "device_hostname_rdns_settings"
    repo ServiceRadar.Repo
    schema "platform"
  end

  oban do
    triggers do
      trigger :run_hostname_rdns do
        queue :maintenance
        extra_args &ServiceRadar.Oban.AshObanQueueResolver.job_meta/1
        read_action :due
        worker_read_action :read
        scheduler_cron "* * * * *"
        action :run

        scheduler_module_name ServiceRadar.Inventory.DeviceHostnameRdnsSettings.Scheduler
        worker_module_name ServiceRadar.Inventory.DeviceHostnameRdnsSettings.Worker
      end
    end
  end

  code_interface do
    define :get_settings, action: :get_singleton
    define :create_settings, action: :create
    define :update_settings, action: :update
    define :run_now, action: :run_now
  end

  actions do
    defaults [:read]

    read :get_singleton do
      description "Get the singleton reverse-DNS hostname settings"
      get? true
      filter expr(key == "default")
    end

    read :due do
      description "Enabled reverse-DNS settings whose next_run_at is due"
      filter expr(key == "default" and enabled == true and next_run_at <= now())
      pagination keyset?: true, default_limit: 1
    end

    create :create do
      description "Create reverse-DNS hostname settings"
      accept @settings_fields
      change set_attribute(:key, "default")
      validate &validate_cron/2
      validate &validate_srql/2
      change &set_initial_next_run/2
    end

    update :update do
      description "Update reverse-DNS hostname settings"
      require_atomic? false
      accept @settings_fields
      validate &validate_cron/2
      validate &validate_srql/2
      change &refresh_next_run_on_schedule_change/2
    end

    update :run do
      description "Run scheduled reverse-DNS hostname enrichment"
      require_atomic? false

      change fn changeset, _context ->
        apply_run(changeset)
      end
    end

    update :run_now do
      description "Run operator-requested reverse-DNS hostname enrichment without the retry delay"
      require_atomic? false

      change fn changeset, _context ->
        apply_run(changeset, ignore_retry?: true)
      end
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    # AshOban scheduler uses :due; the worker reloads via worker_read_action
    # :read (and then runs :run) with a nil actor.
    bypass action([:due, :read, :get_singleton, :run]) do
      authorize_if ActorIsNil
    end

    read_operator_plus()
    operator_action([:create, :update, :run_now])
  end

  attributes do
    attribute :key, :string do
      allow_nil? false
      default "default"
      primary_key? true
      public? false
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default true
      public? true
      description "Whether scheduled reverse-DNS hostname enrichment is enabled"
    end

    attribute :cron, :string do
      allow_nil? false
      default @default_cron
      public? true
      constraints min_length: 1, max_length: 100
      description "Cron expression for the reverse-DNS job"
    end

    attribute :timezone, :string do
      allow_nil? false
      default "Etc/UTC"
      public? true
      constraints max_length: 50
      description "Timezone used to evaluate the cron expression"
    end

    attribute :srql_query, :string do
      allow_nil? false
      default @default_srql_query
      public? true
      constraints min_length: 1, max_length: 4_000
      description "SRQL query that selects the reverse-DNS device cohort"
    end

    attribute :batch_size, :integer do
      allow_nil? false
      default 200
      public? true
      constraints min: 1, max: 5_000
      description "Devices loaded and processed per batch while exhausting the selected cohort"
    end

    attribute :timeout_ms, :integer do
      allow_nil? false
      default 250
      public? true
      constraints min: 50, max: 5_000
      description "Per-IP reverse-DNS timeout in milliseconds"
    end

    attribute :retry_after_minutes, :integer do
      allow_nil? false
      default 1_440
      public? true
      constraints min: 5, max: 43_200
      description "Minimum minutes between scheduled PTR lookups for a device"
    end

    attribute :overwrite_existing, :boolean do
      allow_nil? false
      default false
      public? true
      description "When true, refresh hostnames that already have a non-IP value"
    end

    attribute :last_run_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_success_at, :utc_datetime_usec do
      public? true
    end

    attribute :next_run_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_status, :string do
      public? true
    end

    attribute :last_error, :string do
      public? true
    end

    attribute :last_looked_up, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :last_updated, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :last_cohort_rows, :integer do
      allow_nil? false
      default 0
      public? true
      description "SRQL rows scanned in the last run"
    end

    attribute :last_candidates, :integer do
      allow_nil? false
      default 0
      public? true
      description "Devices eligible for reverse DNS after last-run filters"
    end

    timestamps()
  end

  def default_cron, do: @default_cron

  def default_srql_query, do: @default_srql_query

  defp validate_cron(changeset, _context) do
    cron = Ash.Changeset.get_attribute(changeset, :cron)

    cond do
      is_nil(cron) or cron == "" ->
        {:error, field: :cron, message: "cannot be empty"}

      invalid_cron?(cron) ->
        {:error, field: :cron, message: "is not a valid cron expression"}

      true ->
        :ok
    end
  end

  defp set_initial_next_run(changeset, _context) do
    Ash.Changeset.change_attribute(changeset, :next_run_at, DateTime.utc_now())
  end

  defp refresh_next_run_on_schedule_change(changeset, _context) do
    enabled = Ash.Changeset.get_attribute(changeset, :enabled)

    if enabled == true and schedule_fields_changing?(changeset) do
      Ash.Changeset.change_attribute(changeset, :next_run_at, DateTime.utc_now())
    else
      changeset
    end
  end

  defp schedule_fields_changing?(changeset) do
    Enum.any?([:enabled, :cron, :timezone], &Ash.Changeset.changing_attribute?(changeset, &1))
  end

  defp apply_run(changeset, opts \\ []) do
    settings = changeset.data
    now = DateTime.utc_now()

    Logger.info("DeviceHostnameRdns: starting run", query: settings.srql_query)

    # Device reads/updates always use the system actor so operator Run now is
    # not blocked by a missing devices.view / devices.update grant.
    case DeviceHostnameRdns.run(settings,
           actor: SystemActor.system(:device_hostname_rdns),
           now: now,
           ignore_retry?: Keyword.get(opts, :ignore_retry?, false)
         ) do
      {:ok, stats} ->
        changeset
        |> Ash.Changeset.change_attribute(:last_run_at, now)
        |> Ash.Changeset.change_attribute(:last_success_at, now)
        |> Ash.Changeset.change_attribute(:next_run_at, next_run_after(settings, now, stats))
        |> Ash.Changeset.change_attribute(:last_status, "ok")
        |> Ash.Changeset.change_attribute(:last_error, empty_run_hint(stats))
        |> Ash.Changeset.change_attribute(:last_looked_up, stats.looked_up)
        |> Ash.Changeset.change_attribute(:last_updated, stats.updated)
        |> Ash.Changeset.change_attribute(:last_cohort_rows, stats.cohort_rows)
        |> Ash.Changeset.change_attribute(:last_candidates, stats.candidates)

      {:error, reason} ->
        Logger.warning("DeviceHostnameRdns: run failed", reason: inspect(reason))

        changeset
        |> Ash.Changeset.change_attribute(:last_run_at, now)
        |> Ash.Changeset.change_attribute(:next_run_at, DateTime.add(now, 60, :second))
        |> Ash.Changeset.change_attribute(:last_status, "error")
        |> Ash.Changeset.change_attribute(:last_error, format_run_error(reason))
        |> Ash.Changeset.change_attribute(:last_looked_up, 0)
        |> Ash.Changeset.change_attribute(:last_updated, 0)
        |> Ash.Changeset.change_attribute(:last_cohort_rows, 0)
        |> Ash.Changeset.change_attribute(:last_candidates, 0)
    end
  end

  defp empty_run_hint(stats) do
    cond do
      stats.looked_up > 0 ->
        nil

      stats.cohort_rows == 0 ->
        "SRQL matched 0 devices"

      stats.candidates == 0 ->
        "SRQL matched #{stats.cohort_rows} device(s); none were eligible (already named, no IP, or recently looked up)"

      true ->
        "Selected #{stats.candidates} eligible device(s) but none could be loaded"
    end
  end

  defp next_run_after(settings, now, _stats) do
    next_cron_due(settings.cron, settings.timezone, now) || DateTime.add(now, 3_600, :second)
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
      {:ok, _} -> false
      _ -> true
    end
  end

  defp validate_srql(changeset, _context) do
    query = Ash.Changeset.get_attribute(changeset, :srql_query)

    if is_nil(query) or String.trim(to_string(query)) == "" do
      {:error, field: :srql_query, message: "cannot be empty"}
    else
      normalized = SRQLQuery.ensure_target(query, :devices)

      if SRQLAst.entity(normalized) == "devices" do
        case SRQLAst.validate(normalized) do
          :ok ->
            :ok

          {:error, reason} ->
            {:error, field: :srql_query, message: "is not valid SRQL (#{inspect(reason)})"}
        end
      else
        {:error, field: :srql_query, message: "must target devices"}
      end
    end
  end

  defp format_run_error(reason) when is_binary(reason), do: reason
  defp format_run_error(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp format_run_error({reason, detail}) when is_atom(reason),
    do: "#{reason}: #{inspect(detail)}"

  defp format_run_error(reason), do: inspect(reason)

  defp normalize_timezone(timezone) when timezone in ["UTC", "Etc/UTC"], do: "Etc/UTC"
  defp normalize_timezone(_timezone), do: "Etc/UTC"
end
