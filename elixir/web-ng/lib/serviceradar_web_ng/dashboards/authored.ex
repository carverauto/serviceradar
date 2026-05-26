defmodule ServiceRadarWebNG.Dashboards.Authored do
  @moduledoc """
  Context for user-authored SRQL dashboards.
  """

  alias Oban.Cron.Expression
  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadar.Dashboards.DashboardAccessGrant
  alias ServiceRadar.Dashboards.DashboardPanel
  alias ServiceRadar.Dashboards.DashboardReportDelivery
  alias ServiceRadar.Dashboards.DashboardReportSchedule
  alias ServiceRadar.Dashboards.DashboardUserPreference
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadar.Identity.UserGroupMembership
  alias ServiceRadar.Repo

  require Ash.Query

  @dashboard_ref_min 1_000_000
  @dashboard_ref_max 9_999_999
  @dashboard_slug_pattern ~r/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/
  @dashboard_route_ref_pattern ~r/^\d{7}$/
  @reserved_dashboard_slugs MapSet.new([
                              "new",
                              "edit",
                              "settings",
                              "packages",
                              "package",
                              "default",
                              "search",
                              "service-availability-noc"
                            ])
  @default_limit 50
  @max_limit 200
  @preview_limit 100
  @default_timezone "UTC"
  @max_panel_refresh_interval_seconds 86_400
  @max_schedule_recipients 50

  @visuals [
    %{
      type: :table,
      label: "Table",
      description: "Rows and columns for any SRQL result."
    },
    %{
      type: :stat,
      label: "Stat",
      description: "Single numeric value with an optional label."
    },
    %{
      type: :count,
      label: "Count",
      description: "Current count with optional trend-over-time comparison."
    },
    %{
      type: :gauge,
      label: "Gauge",
      description: "Bounded value with thresholds, units, and a prominent label."
    },
    %{
      type: :availability,
      label: "Availability",
      description: "Availability ratio from explicit numerator and denominator bindings."
    },
    %{
      type: :line,
      label: "Line",
      description: "Time series trend with a timestamp and numeric value."
    },
    %{
      type: :area,
      label: "Area",
      description: "Filled time series trend with a timestamp and numeric value."
    },
    %{
      type: :bar,
      label: "Bar",
      description: "Categorical or ranked numeric comparison."
    },
    %{
      type: :category,
      label: "Category",
      description: "Breakdown by string labels and numeric values."
    },
    %{
      type: :status_list,
      label: "Status List",
      description: "Operational rows with status or health fields."
    },
    %{
      type: :pivot,
      label: "Pivot Table",
      description: "Cross-tab analysis from row, column, and aggregate bindings."
    }
  ]

  @spec list_dashboards(term(), map()) :: [AuthoredDashboard.t()]
  def list_dashboards(scope, filters \\ %{}) do
    limit = normalize_limit(fetch_value(filters, [:limit, "limit"]))

    statuses =
      normalize_existing_atoms(fetch_value(filters, [:status, "status"]), [
        :draft,
        :active,
        :archived
      ])

    query =
      AuthoredDashboard
      |> Ash.Query.for_read(:read)
      |> maybe_filter_status(statuses)
      |> Ash.Query.limit(limit)
      |> Ash.Query.sort(updated_at: :desc)

    read!(query, scope)
  end

  @spec list_dashboard_preferences(term()) :: [DashboardUserPreference.t()]
  def list_dashboard_preferences(scope) do
    case owner_id(scope) do
      user_id when is_binary(user_id) ->
        DashboardUserPreference
        |> Ash.Query.for_read(:for_user, %{user_id: user_id})
        |> Ash.Query.sort(is_default: :desc, favorite: :desc, updated_at: :desc)
        |> read!(scope)

      _ ->
        []
    end
  end

  @spec set_dashboard_favorite(term(), atom(), String.t(), boolean()) ::
          {:ok, DashboardUserPreference.t()} | {:error, term()}
  def set_dashboard_favorite(scope, target_type, target_id, favorite?)
      when target_type in [:authored, :package] and is_binary(target_id) and is_boolean(favorite?) do
    attrs = preference_attrs(scope, target_type, target_id, %{favorite: favorite?})

    DashboardUserPreference
    |> Ash.Changeset.for_create(:upsert, attrs)
    |> create(scope)
  end

  def set_dashboard_favorite(_scope, _target_type, _target_id, _favorite?), do: {:error, :invalid_attributes}

  @spec set_default_dashboard(term(), atom(), String.t()) ::
          {:ok, DashboardUserPreference.t()} | {:error, term()}
  def set_default_dashboard(scope, target_type, target_id)
      when target_type in [:authored, :package] and is_binary(target_id) do
    with :ok <- clear_default_dashboard(scope) do
      attrs = preference_attrs(scope, target_type, target_id, %{favorite: true, is_default: true})

      DashboardUserPreference
      |> Ash.Changeset.for_create(:upsert, attrs)
      |> create(scope)
    end
  end

  def set_default_dashboard(_scope, _target_type, _target_id), do: {:error, :invalid_attributes}

  @spec get_dashboard(term(), String.t(), keyword()) ::
          {:ok, AuthoredDashboard.t()} | {:error, :not_found} | {:error, term()}
  def get_dashboard(scope, id, opts \\ [])

  def get_dashboard(scope, id, opts) when is_binary(id) do
    load = Keyword.get(opts, :load, [:panels, :report_schedules])

    case dashboard_lookup(id) do
      {:id, uuid} ->
        AuthoredDashboard
        |> Ash.Query.for_read(:by_id, %{id: uuid})
        |> Ash.Query.load(load)
        |> read_one(scope)

      {:ref, dashboard_ref} ->
        AuthoredDashboard
        |> Ash.Query.for_read(:by_ref, %{dashboard_ref: dashboard_ref})
        |> Ash.Query.load(load)
        |> read_one(scope)

      {:slug, slug} ->
        get_dashboard_by_slug(scope, slug, opts)
    end
  end

  def get_dashboard(_scope, _id, _opts), do: {:error, :not_found}

  @spec get_dashboard_by_slug(term(), String.t(), keyword()) ::
          {:ok, AuthoredDashboard.t()} | {:error, :not_found} | {:error, term()}
  def get_dashboard_by_slug(scope, slug, opts \\ [])

  def get_dashboard_by_slug(scope, slug, opts) when is_binary(slug) do
    load = Keyword.get(opts, :load, [:panels, :report_schedules])

    query =
      AuthoredDashboard
      |> Ash.Query.for_read(:by_slug, %{slug: slug})
      |> Ash.Query.load(load)

    read_one(query, scope)
  end

  def get_dashboard_by_slug(_scope, _slug, _opts), do: {:error, :not_found}

  @spec create_dashboard(term(), map()) :: {:ok, AuthoredDashboard.t()} | {:error, term()}
  def create_dashboard(scope, attrs) when is_map(attrs) do
    with {:ok, attrs} <- validate_dashboard_attrs(dashboard_attrs(attrs)) do
      create_dashboard_with_ref(scope, attrs, 0)
    end
  end

  def create_dashboard(_scope, _attrs), do: {:error, :invalid_attributes}

  @spec create_dashboard_with_panels(term(), map(), [map()]) ::
          {:ok, {AuthoredDashboard.t(), [DashboardPanel.t()]}} | {:error, term()}
  def create_dashboard_with_panels(scope, attrs, panel_attrs) when is_map(attrs) and is_list(panel_attrs) do
    with {:ok, attrs} <- validate_dashboard_attrs(dashboard_attrs(attrs)) do
      case Repo.transaction(fn ->
             with {:ok, dashboard, dashboard_notifications} <-
                    create_dashboard_with_ref_and_notifications(scope, attrs, 0),
                  {:ok, panels, panel_notifications} <-
                    create_panels_for_dashboard_with_notifications(scope, dashboard, panel_attrs) do
               {dashboard, panels, dashboard_notifications ++ panel_notifications}
             else
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
        {:ok, {dashboard, panels, notifications}} ->
          Ash.Notifier.notify(notifications)
          {:ok, {dashboard, panels}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def create_dashboard_with_panels(_scope, _attrs, _panel_attrs), do: {:error, :invalid_attributes}

  @spec update_dashboard(term(), AuthoredDashboard.t(), map()) ::
          {:ok, AuthoredDashboard.t()} | {:error, term()}
  def update_dashboard(scope, %AuthoredDashboard{} = dashboard, attrs) when is_map(attrs) do
    with {:ok, attrs} <- validate_dashboard_attrs(dashboard_attrs(attrs)) do
      dashboard
      |> Ash.Changeset.for_update(:update, attrs)
      |> update(scope)
    end
  end

  def update_dashboard(_scope, _dashboard, _attrs), do: {:error, :invalid_attributes}

  defp create_dashboard_with_ref(_scope, _attrs, attempts) when attempts >= 8 do
    {:error, :dashboard_ref_generation_failed}
  end

  defp create_dashboard_with_ref(scope, attrs, attempts) do
    dashboard_ref = generate_dashboard_ref()

    if dashboard_ref_taken?(scope, dashboard_ref) do
      create_dashboard_with_ref(scope, attrs, attempts + 1)
    else
      result =
        AuthoredDashboard
        |> Ash.Changeset.for_create(:create, Map.put(attrs, :dashboard_ref, dashboard_ref))
        |> maybe_set_owner(scope)
        |> create(scope)

      case result do
        {:ok, dashboard} -> {:ok, dashboard}
        {:error, reason} -> maybe_retry_dashboard_ref_conflict(scope, attrs, attempts, reason)
      end
    end
  end

  defp create_dashboard_with_ref_and_notifications(_scope, _attrs, attempts) when attempts >= 8 do
    {:error, :dashboard_ref_generation_failed}
  end

  defp create_dashboard_with_ref_and_notifications(scope, attrs, attempts) do
    dashboard_ref = generate_dashboard_ref()

    if dashboard_ref_taken?(scope, dashboard_ref) do
      create_dashboard_with_ref_and_notifications(scope, attrs, attempts + 1)
    else
      result =
        AuthoredDashboard
        |> Ash.Changeset.for_create(:create, Map.put(attrs, :dashboard_ref, dashboard_ref))
        |> maybe_set_owner(scope)
        |> create_with_notifications(scope)

      case result do
        {:ok, dashboard, notifications} ->
          {:ok, dashboard, notifications}

        {:error, reason} ->
          maybe_retry_dashboard_ref_conflict_with_notifications(scope, attrs, attempts, reason)
      end
    end
  end

  defp maybe_retry_dashboard_ref_conflict(scope, attrs, attempts, reason) do
    if unique_dashboard_ref_error?(reason) do
      create_dashboard_with_ref(scope, attrs, attempts + 1)
    else
      {:error, reason}
    end
  end

  defp maybe_retry_dashboard_ref_conflict_with_notifications(scope, attrs, attempts, reason) do
    if unique_dashboard_ref_error?(reason) do
      create_dashboard_with_ref_and_notifications(scope, attrs, attempts + 1)
    else
      {:error, reason}
    end
  end

  defp generate_dashboard_ref do
    @dashboard_ref_min + :rand.uniform(@dashboard_ref_max - @dashboard_ref_min + 1) - 1
  end

  defp dashboard_ref_taken?(scope, dashboard_ref) do
    AuthoredDashboard
    |> Ash.Query.for_read(:by_ref, %{dashboard_ref: dashboard_ref})
    |> read_one(scope)
    |> case do
      {:ok, %AuthoredDashboard{}} -> true
      _ -> false
    end
  end

  defp unique_dashboard_ref_error?(reason) do
    reason
    |> inspect()
    |> String.contains?("authored_dashboards_dashboard_ref")
  end

  @spec archive_dashboard(term(), AuthoredDashboard.t()) ::
          {:ok, AuthoredDashboard.t()} | {:error, term()}
  def archive_dashboard(scope, %AuthoredDashboard{} = dashboard) do
    dashboard
    |> Ash.Changeset.for_update(:archive, %{})
    |> update(scope)
  end

  @spec list_panels(term(), String.t()) :: [DashboardPanel.t()]
  def list_panels(scope, dashboard_id) when is_binary(dashboard_id) do
    DashboardPanel
    |> Ash.Query.for_read(:for_dashboard, %{dashboard_id: dashboard_id})
    |> read!(scope)
  end

  def list_panels(_scope, _dashboard_id), do: []

  @spec create_panel(term(), map()) :: {:ok, DashboardPanel.t()} | {:error, term()}
  def create_panel(scope, attrs) when is_map(attrs) do
    attrs = panel_attrs(attrs)

    with {:ok, attrs} <- validate_panel_attrs(scope, attrs) do
      DashboardPanel
      |> Ash.Changeset.for_create(:create, attrs)
      |> create(scope)
    end
  end

  def create_panel(_scope, _attrs), do: {:error, :invalid_attributes}

  defp create_panels_for_dashboard_with_notifications(scope, %AuthoredDashboard{} = dashboard, panel_attrs) do
    panel_attrs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], []}, fn {attrs, index}, {:ok, panels, notifications} ->
      attrs =
        attrs
        |> Map.put(:dashboard_id, dashboard.id)
        |> Map.put_new(:position, index)

      case create_panel_with_notifications(scope, attrs) do
        {:ok, panel, panel_notifications} ->
          {:cont, {:ok, panels ++ [panel], notifications ++ panel_notifications}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp create_panel_with_notifications(scope, attrs) when is_map(attrs) do
    attrs = panel_attrs(attrs)

    with {:ok, attrs} <- validate_panel_attrs(scope, attrs) do
      DashboardPanel
      |> Ash.Changeset.for_create(:create, attrs)
      |> create_with_notifications(scope)
    end
  end

  @spec update_panel(term(), DashboardPanel.t(), map()) ::
          {:ok, DashboardPanel.t()} | {:error, term()}
  def update_panel(scope, %DashboardPanel{} = panel, attrs) when is_map(attrs) do
    attrs =
      panel
      |> existing_panel_attrs()
      |> Map.merge(panel_attrs(attrs))

    with {:ok, attrs} <- validate_panel_attrs(scope, attrs) do
      panel
      |> Ash.Changeset.for_update(:update, Map.delete(attrs, :dashboard_id))
      |> update(scope)
    end
  end

  def update_panel(_scope, _panel, _attrs), do: {:error, :invalid_attributes}

  @spec delete_panel(term(), DashboardPanel.t()) :: :ok | {:error, term()}
  def delete_panel(scope, %DashboardPanel{} = panel) do
    destroy_result(destroy(panel, scope))
  end

  @spec list_report_schedules(term(), String.t()) :: [DashboardReportSchedule.t()]
  def list_report_schedules(scope, dashboard_id) when is_binary(dashboard_id) do
    DashboardReportSchedule
    |> Ash.Query.for_read(:for_dashboard, %{dashboard_id: dashboard_id})
    |> read!(scope)
  end

  def list_report_schedules(_scope, _dashboard_id), do: []

  @spec create_report_schedule(term(), map()) ::
          {:ok, DashboardReportSchedule.t()} | {:error, term()}
  def create_report_schedule(scope, attrs) when is_map(attrs) do
    attrs = schedule_attrs(attrs)

    with {:ok, attrs} <- validate_schedule_attrs(attrs) do
      attrs = maybe_put_next_due_at(attrs)

      DashboardReportSchedule
      |> Ash.Changeset.for_create(:create, attrs)
      |> create(scope)
    end
  end

  def create_report_schedule(_scope, _attrs), do: {:error, :invalid_attributes}

  @spec update_report_schedule(term(), DashboardReportSchedule.t(), map()) ::
          {:ok, DashboardReportSchedule.t()} | {:error, term()}
  def update_report_schedule(scope, %DashboardReportSchedule{} = schedule, attrs) when is_map(attrs) do
    attrs =
      schedule
      |> existing_schedule_attrs()
      |> Map.merge(schedule_attrs(attrs))

    with {:ok, attrs} <- validate_schedule_attrs(attrs) do
      attrs =
        attrs
        |> Map.delete(:dashboard_id)
        |> maybe_put_next_due_at()

      schedule
      |> Ash.Changeset.for_update(:update, attrs)
      |> update(scope)
    end
  end

  def update_report_schedule(_scope, _schedule, _attrs), do: {:error, :invalid_attributes}

  @spec delete_report_schedule(term(), DashboardReportSchedule.t()) :: :ok | {:error, term()}
  def delete_report_schedule(scope, %DashboardReportSchedule{} = schedule) do
    destroy_result(destroy(schedule, scope))
  end

  def delete_report_schedule(_scope, _schedule), do: {:error, :invalid_attributes}

  defp validate_panel_attrs(scope, attrs) do
    srql_query = Map.get(attrs, :srql_query)
    visual_type = Map.get(attrs, :visual_type, :table)

    with :ok <- validate_visual_type(visual_type),
         :ok <- validate_panel_refresh_interval(Map.get(attrs, :refresh_interval_seconds, 0)),
         :ok <- validate_map_attr(attrs, :visual_config),
         :ok <- validate_map_attr(attrs, :builder_state),
         :ok <- validate_map_attr(attrs, :data_binding),
         :ok <- validate_map_attr(attrs, :display_config),
         :ok <- validate_map_attr(attrs, :layout),
         {:ok, preview} <- preview_query(scope, srql_query),
         :ok <- validate_visual_compatibility(visual_type, preview.compatible_visuals),
         :ok <- validate_data_binding(visual_type, Map.get(attrs, :data_binding, %{}), preview.fields),
         :ok <- validate_display_config(Map.get(attrs, :display_config, %{}), preview.fields),
         :ok <- validate_visual_config(Map.get(attrs, :visual_config, %{}), preview.fields) do
      field_metadata =
        attrs
        |> Map.get(:field_metadata, %{})
        |> Map.merge(%{
          fields: preview.fields,
          compatible_visuals: preview.compatible_visuals,
          validated_at: DateTime.to_iso8601(DateTime.utc_now())
        })

      {:ok, Map.put(attrs, :field_metadata, field_metadata)}
    end
  end

  defp validate_visual_type(type)
       when type in [:table, :stat, :count, :gauge, :availability, :line, :area, :bar, :category, :status_list, :pivot] do
    :ok
  end

  defp validate_visual_type(type), do: {:error, {:unsupported_visual_type, type}}

  # Tables are the catch-all rendering path for any tabular SRQL result shape.
  defp validate_visual_compatibility(:table, _compatible), do: :ok

  defp validate_visual_compatibility(:gauge, compatible), do: validate_visual_compatibility(:stat, compatible)

  defp validate_visual_compatibility(type, compatible) do
    if type in compatible do
      :ok
    else
      {:error, {:incompatible_visual_type, type, compatible}}
    end
  end

  defp validate_data_binding(:availability, binding, fields) when is_map(binding) do
    with :ok <- validate_required_binding(binding, fields, "numerator_field"),
         :ok <- validate_required_binding(binding, fields, "denominator_field") do
      validate_optional_bindings(binding, fields)
    end
  end

  defp validate_data_binding(_visual_type, binding, fields) when is_map(binding) do
    validate_optional_bindings(binding, fields)
  end

  defp validate_data_binding(_visual_type, binding, _fields), do: {:error, {:invalid_data_binding, binding}}

  defp validate_required_binding(binding, fields, key) do
    case Map.get(binding, key) do
      value when is_binary(value) and value != "" ->
        validate_field_name(fields, value, {:missing_binding_field, key, value})

      _ ->
        {:error, {:required_binding_field, key}}
    end
  end

  defp validate_optional_bindings(binding, fields) do
    binding
    |> Enum.filter(fn {key, value} ->
      String.ends_with?(to_string(key), "_field") and is_binary(value) and value != ""
    end)
    |> Enum.reduce_while(:ok, fn {key, value}, :ok ->
      case validate_field_name(fields, value, {:missing_binding_field, to_string(key), value}) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_display_config(config, fields) when is_map(config) do
    config
    |> Map.get("table_columns", [])
    |> validate_table_columns(fields)
  end

  defp validate_display_config(config, _fields), do: {:error, {:invalid_display_config, config}}

  defp validate_visual_config(config, fields) when is_map(config) do
    config
    |> visual_config_field_refs()
    |> Enum.reduce_while(:ok, fn {key, field}, :ok ->
      case validate_field_name(fields, field, {:missing_visual_config_field, key, field}) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_visual_config(config, _fields), do: {:error, {:invalid_visual_config, config}}

  defp visual_config_field_refs(config) do
    top_level =
      config
      |> Enum.filter(fn {key, value} ->
        String.ends_with?(to_string(key), "_field") and is_binary(value) and value != ""
      end)
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)

    threshold_refs =
      config
      |> Map.get("thresholds", [])
      |> case do
        thresholds when is_list(thresholds) ->
          thresholds
          |> Enum.filter(&is_map/1)
          |> Enum.flat_map(fn threshold ->
            case Map.get(threshold, "field") || Map.get(threshold, :field) do
              field when is_binary(field) and field != "" -> [{"thresholds.field", field}]
              _ -> []
            end
          end)

        _ ->
          []
      end

    top_level ++ threshold_refs
  end

  defp validate_table_columns([], _fields), do: :ok
  defp validate_table_columns(nil, _fields), do: :ok

  defp validate_table_columns(columns, fields) when is_list(columns) do
    Enum.reduce_while(columns, :ok, fn
      %{} = column, :ok ->
        field = Map.get(column, "field") || Map.get(column, :field)

        case validate_field_name(fields, field, {:missing_table_column_field, field}) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      column, :ok ->
        {:halt, {:error, {:invalid_table_column, column}}}
    end)
  end

  defp validate_table_columns(columns, _fields), do: {:error, {:invalid_table_columns, columns}}

  defp validate_field_name(_fields, nil, _reason), do: :ok
  defp validate_field_name(_fields, "", _reason), do: :ok

  defp validate_field_name(fields, field, reason) when is_binary(field) do
    if Enum.any?(fields, &(&1.name == field)), do: :ok, else: {:error, reason}
  end

  defp validate_field_name(_fields, field, _reason), do: {:error, {:invalid_field_reference, field}}

  defp validate_panel_refresh_interval(value)
       when is_integer(value) and value >= 0 and value <= @max_panel_refresh_interval_seconds do
    :ok
  end

  defp validate_panel_refresh_interval(value) do
    {:error, {:invalid_refresh_interval_seconds, value, 0, @max_panel_refresh_interval_seconds}}
  end

  defp validate_map_attr(attrs, key) do
    case Map.get(attrs, key, %{}) do
      value when is_map(value) -> :ok
      value -> {:error, {:invalid_map_attribute, key, value}}
    end
  end

  defp validate_schedule_attrs(attrs) do
    with :ok <- validate_recipients(Map.get(attrs, :recipients, [])),
         :ok <- validate_cron(Map.get(attrs, :cron)),
         :ok <- validate_timezone(Map.get(attrs, :timezone, @default_timezone)) do
      {:ok, attrs}
    end
  end

  defp validate_recipients(recipients) when is_list(recipients) do
    cond do
      recipients == [] ->
        {:error, :report_schedule_recipients_required}

      length(recipients) > @max_schedule_recipients ->
        {:error, {:too_many_report_recipients, length(recipients), @max_schedule_recipients}}

      invalid = Enum.find(recipients, &(not valid_email?(&1))) ->
        {:error, {:invalid_report_recipient, invalid}}

      true ->
        :ok
    end
  end

  defp validate_recipients(value), do: {:error, {:invalid_report_recipients, value}}

  defp validate_cron(cron) when is_binary(cron) do
    case Expression.parse(cron) do
      {:ok, _expr} -> :ok
      _ -> {:error, {:invalid_report_cron, cron}}
    end
  end

  defp validate_cron(value), do: {:error, {:invalid_report_cron, value}}

  defp validate_timezone(timezone) when timezone in ["UTC", "Etc/UTC"], do: :ok

  defp validate_timezone(timezone) when is_binary(timezone) do
    case DateTime.shift_zone(DateTime.utc_now(), normalize_timezone(timezone)) do
      {:ok, _datetime} -> :ok
      _ -> {:error, {:invalid_report_timezone, timezone}}
    end
  end

  defp validate_timezone(value), do: {:error, {:invalid_report_timezone, value}}

  defp valid_email?(value) when is_binary(value) do
    value =~ ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/
  end

  defp valid_email?(_value), do: false

  defp existing_panel_attrs(%DashboardPanel{} = panel) do
    %{
      dashboard_id: panel.dashboard_id,
      dataset_key: panel.dataset_key || "primary",
      title: panel.title,
      srql_query: panel.srql_query,
      builder_state: panel.builder_state || %{},
      visual_type: panel.visual_type,
      data_binding: panel.data_binding || %{},
      display_config: panel.display_config || %{},
      visual_config: panel.visual_config || %{},
      field_metadata: panel.field_metadata || %{},
      layout: panel.layout || %{},
      refresh_interval_seconds: panel.refresh_interval_seconds || 0,
      position: panel.position || 0,
      metadata: panel.metadata || %{}
    }
  end

  defp existing_schedule_attrs(%DashboardReportSchedule{} = schedule) do
    %{
      dashboard_id: schedule.dashboard_id,
      name: schedule.name,
      enabled: schedule.enabled,
      recipients: schedule.recipients || [],
      cron: schedule.cron,
      timezone: schedule.timezone || @default_timezone,
      format: schedule.format || :html,
      next_due_at: schedule.next_due_at,
      metadata: schedule.metadata || %{}
    }
  end

  @spec list_report_deliveries(term(), String.t()) :: [DashboardReportDelivery.t()]
  def list_report_deliveries(scope, dashboard_id) when is_binary(dashboard_id) do
    DashboardReportDelivery
    |> Ash.Query.for_read(:for_dashboard, %{dashboard_id: dashboard_id})
    |> Ash.Query.limit(25)
    |> read!(scope)
  end

  def list_report_deliveries(_scope, _dashboard_id), do: []

  @spec list_access_grants(term(), String.t()) :: [DashboardAccessGrant.t()]
  def list_access_grants(scope, dashboard_id) when is_binary(dashboard_id) do
    DashboardAccessGrant
    |> Ash.Query.for_read(:for_dashboard, %{dashboard_id: dashboard_id})
    |> Ash.Query.load([:subject_user, :subject_group])
    |> Ash.Query.sort(inserted_at: :asc)
    |> read!(scope)
  end

  def list_access_grants(_scope, _dashboard_id), do: []

  @spec grant_dashboard_to_user(term(), map()) ::
          {:ok, DashboardAccessGrant.t()} | {:error, term()}
  def grant_dashboard_to_user(scope, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> access_grant_attrs()
      |> Map.put(:subject_type, :user)
      |> Map.put_new(:granted_by_id, owner_id(scope))

    DashboardAccessGrant
    |> Ash.Changeset.for_create(:create, attrs)
    |> create(scope)
  end

  def grant_dashboard_to_user(_scope, _attrs), do: {:error, :invalid_attributes}

  @spec grant_dashboard_to_group(term(), map()) ::
          {:ok, DashboardAccessGrant.t()} | {:error, term()}
  def grant_dashboard_to_group(scope, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> access_grant_attrs()
      |> Map.put(:subject_type, :group)
      |> Map.put_new(:granted_by_id, owner_id(scope))

    DashboardAccessGrant
    |> Ash.Changeset.for_create(:create_group, attrs)
    |> create(scope)
  end

  def grant_dashboard_to_group(_scope, _attrs), do: {:error, :invalid_attributes}

  @spec revoke_access_grant(term(), DashboardAccessGrant.t()) :: :ok | {:error, term()}
  def revoke_access_grant(scope, %DashboardAccessGrant{} = grant) do
    destroy_result(destroy(grant, scope))
  end

  @spec list_user_groups(term()) :: [UserGroup.t()]
  def list_user_groups(scope) do
    UserGroup
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(name: :asc)
    |> read!(scope)
  end

  @spec list_user_group_memberships(term(), String.t() | nil) :: [UserGroupMembership.t()]
  def list_user_group_memberships(scope, group_id \\ nil)

  def list_user_group_memberships(scope, group_id) when is_binary(group_id) do
    UserGroupMembership
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(group_id == ^group_id)
    |> Ash.Query.load([:user, :group])
    |> Ash.Query.sort(inserted_at: :asc)
    |> read!(scope)
  end

  def list_user_group_memberships(scope, _group_id) do
    UserGroupMembership
    |> Ash.Query.for_read(:read)
    |> Ash.Query.load([:user, :group])
    |> Ash.Query.sort(inserted_at: :asc)
    |> read!(scope)
  end

  @spec create_user_group(term(), map()) :: {:ok, UserGroup.t()} | {:error, term()}
  def create_user_group(scope, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> user_group_attrs()
      |> Map.put_new(:owner_id, owner_id(scope))

    UserGroup
    |> Ash.Changeset.for_create(:create, attrs)
    |> create(scope)
  end

  def create_user_group(_scope, _attrs), do: {:error, :invalid_attributes}

  @spec add_user_group_member(term(), map()) :: {:ok, UserGroupMembership.t()} | {:error, term()}
  def add_user_group_member(scope, attrs) when is_map(attrs) do
    UserGroupMembership
    |> Ash.Changeset.for_create(:create, user_group_membership_attrs(attrs))
    |> create(scope)
  end

  def add_user_group_member(_scope, _attrs), do: {:error, :invalid_attributes}

  @spec list_share_principals(term()) :: [User.t()]
  def list_share_principals(scope) do
    User
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(status == :active)
    |> Ash.Query.limit(500)
    |> Ash.Query.sort(email: :asc)
    |> read!(scope)
  end

  @spec visual_options() :: [map()]
  def visual_options, do: @visuals

  @spec preview_query(term(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def preview_query(scope, srql_query, opts \\ [])

  def preview_query(scope, srql_query, opts) when is_binary(srql_query) do
    query = String.trim(srql_query)
    limit = opts |> Keyword.get(:limit, @preview_limit) |> normalize_limit()
    srql_module = Keyword.get(opts, :srql_module, srql_module())

    if query == "" do
      {:error, :empty_query}
    else
      case srql_module.query(query, %{scope: scope, limit: limit}) do
        {:ok, %{"results" => results} = response} ->
          rows = normalize_rows(results)
          fields = infer_fields(rows)

          {:ok,
           %{
             query: query,
             rows: rows,
             row_count: length(rows),
             fields: fields,
             compatible_visuals: compatible_visuals(rows, fields),
             viz: Map.get(response, "viz"),
             pagination: Map.get(response, "pagination")
           }}

        {:ok, response} ->
          {:ok,
           %{
             query: query,
             rows: [],
             row_count: 0,
             fields: [],
             compatible_visuals: [:table],
             raw: response
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def preview_query(_scope, _srql_query, _opts), do: {:error, :empty_query}

  @spec compatible_visuals([map()], [map()]) :: [atom()]
  def compatible_visuals(rows, fields) when is_list(rows) and is_list(fields) do
    field_types = MapSet.new(Enum.map(fields, & &1.type))

    [:table]
    |> maybe_add_visual(:stat, stat_compatible?(rows, fields))
    |> maybe_add_visual(:count, stat_compatible?(rows, fields))
    |> maybe_add_visual(:gauge, Enum.any?(fields, fn field -> field.type == :number end))
    |> maybe_add_visual(:availability, availability_compatible?(fields))
    |> maybe_add_visual(
      :line,
      MapSet.member?(field_types, :datetime) and MapSet.member?(field_types, :number)
    )
    |> maybe_add_visual(
      :area,
      MapSet.member?(field_types, :datetime) and MapSet.member?(field_types, :number)
    )
    |> maybe_add_visual(:bar, MapSet.member?(field_types, :number) and not Enum.empty?(fields))
    |> maybe_add_visual(
      :category,
      MapSet.member?(field_types, :string) and MapSet.member?(field_types, :number)
    )
    |> maybe_add_visual(:status_list, status_compatible?(fields))
    |> maybe_add_visual(:pivot, pivot_compatible?(fields))
  end

  def compatible_visuals(_rows, _fields), do: [:table]

  defp pivot_compatible?(fields) do
    dimension_count = Enum.count(fields, &(&1.type in [:string, :boolean, :datetime]))
    has_numeric? = Enum.any?(fields, &(&1.type == :number))

    dimension_count >= 2 and has_numeric?
  end

  @spec infer_fields([map()]) :: [map()]
  def infer_fields(rows) when is_list(rows) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn name ->
      values = values_for(rows, name)
      type = infer_type(values)

      %{
        id: name,
        name: name,
        type: type,
        sample: Enum.find(values, &present?/1),
        json_paths: json_paths(values),
        aggregate_compatible: type == :number,
        compatible_aggregations: compatible_aggregations(type)
      }
    end)
  end

  def infer_fields(_rows), do: []

  defp json_paths(values) do
    values
    |> Enum.find(&is_map/1)
    |> case do
      nil ->
        []

      value ->
        value
        |> flatten_json_paths()
        |> Enum.uniq()
        |> Enum.sort()
    end
  end

  defp flatten_json_paths(value, prefix \\ "")

  defp flatten_json_paths(value, prefix) when is_map(value) do
    Enum.flat_map(value, fn {key, nested} ->
      path =
        [prefix, to_string(key)]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(".")

      case nested do
        nested when is_map(nested) -> [path | flatten_json_paths(nested, path)]
        _ -> [path]
      end
    end)
  end

  defp flatten_json_paths(_value, _prefix), do: []

  defp compatible_aggregations(:number), do: ["avg", "min", "max", "sum", "count"]
  defp compatible_aggregations(:boolean), do: ["count"]
  defp compatible_aggregations(_type), do: []

  defp read!(query, nil), do: Ash.read!(query)
  defp read!(query, scope), do: Ash.read!(query, scope: scope)

  defp read_one(query, scope) do
    result =
      case scope do
        nil -> Ash.read_one(query)
        _ -> Ash.read_one(query, scope: scope)
      end

    case result do
      {:ok, nil} -> {:error, :not_found}
      {:ok, record} -> {:ok, record}
      {:error, error} -> {:error, error}
    end
  end

  defp create(changeset, nil), do: Ash.create(changeset)
  defp create(changeset, scope), do: Ash.create(changeset, scope: scope)

  defp create_with_notifications(changeset, nil), do: Ash.create(changeset, return_notifications?: true)

  defp create_with_notifications(changeset, scope), do: Ash.create(changeset, scope: scope, return_notifications?: true)

  defp update(changeset, nil), do: Ash.update(changeset)
  defp update(changeset, scope), do: Ash.update(changeset, scope: scope)

  defp destroy(record, nil), do: Ash.destroy(record)
  defp destroy(record, scope), do: Ash.destroy(record, scope: scope)

  defp destroy_result(:ok), do: :ok
  defp destroy_result({:ok, _record}), do: :ok
  defp destroy_result({:error, error}), do: {:error, error}

  defp maybe_set_owner(changeset, scope) do
    case owner_id(scope) do
      user_id when is_binary(user_id) ->
        Ash.Changeset.force_change_attribute(changeset, :owner_id, user_id)

      _ ->
        changeset
    end
  end

  defp validate_dashboard_attrs(attrs) do
    slug = Map.get(attrs, :slug)

    cond do
      not is_binary(slug) ->
        {:ok, attrs}

      MapSet.member?(@reserved_dashboard_slugs, slug) ->
        {:error, {:reserved_dashboard_slug, slug}}

      route_ref_slug?(slug) ->
        {:error, {:route_ref_dashboard_slug, slug}}

      not Regex.match?(@dashboard_slug_pattern, slug) ->
        {:error, {:invalid_dashboard_slug, slug}}

      true ->
        {:ok, attrs}
    end
  end

  defp route_ref_slug?(slug) when is_binary(slug), do: Regex.match?(@dashboard_route_ref_pattern, slug)

  defp dashboard_lookup(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      canonical_uuid?(value) ->
        {:id, value}

      Regex.match?(@dashboard_route_ref_pattern, value) ->
        {dashboard_ref, ""} = Integer.parse(value)
        {:ref, dashboard_ref}

      true ->
        {:slug, slugify(value)}
    end
  end

  defp canonical_uuid?(value) when is_binary(value) do
    Regex.match?(
      ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/,
      value
    )
  end

  defp clear_default_dashboard(scope) do
    scope
    |> list_dashboard_preferences()
    |> Enum.filter(& &1.is_default)
    |> Enum.reduce_while(:ok, fn preference, :ok ->
      case preference
           |> Ash.Changeset.for_update(:clear_default, %{})
           |> update(scope) do
        {:ok, _preference} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp preference_attrs(scope, target_type, target_id, attrs) do
    attrs
    |> Map.put(:user_id, owner_id(scope))
    |> Map.put(:target_type, target_type)
    |> Map.put(:target_id, target_id)
    |> Map.put_new(:favorite, false)
    |> Map.put_new(:is_default, false)
    |> Map.put_new(:metadata, %{})
  end

  defp maybe_filter_status(query, []), do: query
  defp maybe_filter_status(query, statuses), do: Ash.Query.filter(query, status in ^statuses)

  defp dashboard_attrs(attrs) do
    %{}
    |> put_if_present(:title, fetch_string(attrs, [:title, "title"]))
    |> put_if_present(:description, fetch_string(attrs, [:description, "description"]))
    |> put_if_present(:slug, fetch_slug(attrs))
    |> put_if_present(
      :visibility,
      normalize_existing_atom(fetch_value(attrs, [:visibility, "visibility"]), [
        :private,
        :shared,
        :public
      ])
    )
    |> put_if_present(
      :status,
      normalize_existing_atom(fetch_value(attrs, [:status, "status"]), [
        :draft,
        :active,
        :archived
      ])
    )
    |> put_if_present(
      :default_time_range,
      fetch_string(attrs, [:default_time_range, "default_time_range"])
    )
    |> put_if_present(:layout, fetch_map(attrs, [:layout, "layout"]))
    |> put_if_present(:variables, fetch_map(attrs, [:variables, "variables"]))
    |> put_if_present(:metadata, fetch_map(attrs, [:metadata, "metadata"]))
  end

  defp panel_attrs(attrs) do
    %{}
    |> put_if_present(:dashboard_id, fetch_value(attrs, [:dashboard_id, "dashboard_id"]))
    |> put_if_present(:dataset_key, fetch_string(attrs, [:dataset_key, "dataset_key"]))
    |> put_if_present(:title, fetch_string(attrs, [:title, "title"]))
    |> put_if_present(:srql_query, fetch_string(attrs, [:srql_query, "srql_query"]))
    |> put_if_present(:builder_state, fetch_map(attrs, [:builder_state, "builder_state"]))
    |> put_if_present(
      :visual_type,
      normalize_existing_atom(fetch_value(attrs, [:visual_type, "visual_type"]), visual_types())
    )
    |> put_if_present(:data_binding, fetch_map(attrs, [:data_binding, "data_binding"]))
    |> put_if_present(:display_config, fetch_map(attrs, [:display_config, "display_config"]))
    |> put_if_present(:visual_config, fetch_map(attrs, [:visual_config, "visual_config"]))
    |> put_if_present(:field_metadata, fetch_map(attrs, [:field_metadata, "field_metadata"]))
    |> put_if_present(:layout, fetch_map(attrs, [:layout, "layout"]))
    |> put_if_present(
      :refresh_interval_seconds,
      fetch_integer(attrs, [:refresh_interval_seconds, "refresh_interval_seconds"])
    )
    |> put_if_present(:position, fetch_integer(attrs, [:position, "position"]))
    |> put_if_present(:metadata, fetch_map(attrs, [:metadata, "metadata"]))
  end

  defp schedule_attrs(attrs) do
    %{}
    |> put_if_present(:dashboard_id, fetch_value(attrs, [:dashboard_id, "dashboard_id"]))
    |> put_if_present(:name, fetch_string(attrs, [:name, "name"]))
    |> put_if_present(:enabled, fetch_boolean(attrs, [:enabled, "enabled"]))
    |> put_if_present(:recipients, fetch_recipients(attrs))
    |> put_if_present(:cron, fetch_string(attrs, [:cron, "cron"]))
    |> put_if_present(:timezone, fetch_string(attrs, [:timezone, "timezone"]))
    |> put_if_present(
      :format,
      normalize_existing_atom(fetch_value(attrs, [:format, "format"]), [:html])
    )
    |> put_if_present(:next_due_at, fetch_datetime(attrs, [:next_due_at, "next_due_at"]))
    |> put_if_present(:metadata, fetch_map(attrs, [:metadata, "metadata"]))
  end

  defp access_grant_attrs(attrs) do
    %{}
    |> put_if_present(:dashboard_id, fetch_value(attrs, [:dashboard_id, "dashboard_id"]))
    |> put_if_present(
      :subject_user_id,
      fetch_value(attrs, [:subject_user_id, "subject_user_id", :user_id, "user_id"])
    )
    |> put_if_present(
      :subject_group_id,
      fetch_value(attrs, [:subject_group_id, "subject_group_id", :group_id, "group_id"])
    )
    |> put_if_present(
      :access,
      normalize_existing_atom(fetch_value(attrs, [:access, "access"]), [:view, :edit])
    )
    |> put_if_present(:granted_by_id, fetch_value(attrs, [:granted_by_id, "granted_by_id"]))
    |> put_if_present(:metadata, fetch_map(attrs, [:metadata, "metadata"]))
  end

  defp user_group_attrs(attrs) do
    %{}
    |> put_if_present(:name, fetch_string(attrs, [:name, "name"]))
    |> put_if_present(:description, fetch_string(attrs, [:description, "description"]))
    |> put_if_present(:owner_id, fetch_value(attrs, [:owner_id, "owner_id"]))
    |> put_if_present(:metadata, fetch_map(attrs, [:metadata, "metadata"]))
  end

  defp user_group_membership_attrs(attrs) do
    %{}
    |> put_if_present(:group_id, fetch_value(attrs, [:group_id, "group_id"]))
    |> put_if_present(:user_id, fetch_value(attrs, [:user_id, "user_id"]))
    |> put_if_present(
      :role,
      normalize_existing_atom(fetch_value(attrs, [:role, "role"]), [:member, :manager])
    )
    |> put_if_present(:metadata, fetch_map(attrs, [:metadata, "metadata"]))
  end

  defp maybe_put_next_due_at(%{next_due_at: %DateTime{}} = attrs), do: attrs

  defp maybe_put_next_due_at(%{cron: cron} = attrs) when is_binary(cron) do
    timezone = Map.get(attrs, :timezone) || @default_timezone

    case next_due_at(cron, timezone, DateTime.utc_now()) do
      %DateTime{} = next_due_at -> Map.put(attrs, :next_due_at, next_due_at)
      _ -> attrs
    end
  end

  defp maybe_put_next_due_at(attrs), do: attrs

  @spec next_due_at(String.t(), String.t(), DateTime.t()) :: DateTime.t() | nil
  def next_due_at(cron, timezone \\ @default_timezone, after_time \\ DateTime.utc_now())

  def next_due_at(cron, timezone, %DateTime{} = after_time) when is_binary(cron) do
    with {:ok, expr} <- Expression.parse(cron),
         {:ok, base} <- DateTime.shift_zone(after_time, normalize_timezone(timezone)) do
      Expression.next_at(expr, base)
    else
      _ -> nil
    end
  end

  def next_due_at(_cron, _timezone, _after_time), do: nil

  defp normalize_rows(results) when is_list(results) do
    Enum.map(results, fn
      row when is_map(row) -> stringify_keys(row)
      value -> %{"value" => value}
    end)
  end

  defp normalize_rows(_results), do: []

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp values_for(rows, name) do
    Enum.map(rows, fn row -> Map.get(row, name) end)
  end

  defp infer_type(values) do
    cond do
      Enum.any?(values, &datetime?/1) -> :datetime
      Enum.any?(values, &number?/1) -> :number
      Enum.any?(values, &boolean?/1) -> :boolean
      Enum.any?(values, &is_map/1) -> :object
      Enum.any?(values, &is_list/1) -> :list
      true -> :string
    end
  end

  defp datetime?(%DateTime{}), do: true
  defp datetime?(%NaiveDateTime{}), do: true

  defp datetime?(value) when is_binary(value) do
    match?({:ok, _, _}, DateTime.from_iso8601(value)) or
      match?({:ok, _}, NaiveDateTime.from_iso8601(value))
  end

  defp datetime?(_value), do: false

  defp number?(value) when is_integer(value) or is_float(value), do: true

  defp number?(value) when is_binary(value) do
    value = String.trim(value)

    value != "" and
      (match?({_number, ""}, Float.parse(value)) or match?({_number, ""}, Integer.parse(value)))
  end

  defp number?(_value), do: false

  defp boolean?(value) when is_boolean(value), do: true
  defp boolean?(_value), do: false

  defp stat_compatible?([row], fields) when is_map(row) do
    Enum.any?(fields, fn field -> field.type == :number end)
  end

  defp stat_compatible?(_rows, _fields), do: false

  defp status_compatible?(fields) do
    Enum.any?(fields, fn field ->
      field.name in ["status", "state", "health", "result", "severity", "severity_label"]
    end)
  end

  defp availability_compatible?(fields) do
    names = MapSet.new(Enum.map(fields, & &1.name))

    MapSet.member?(names, "total") and
      (MapSet.member?(names, "ok") or MapSet.member?(names, "available"))
  end

  defp maybe_add_visual(visuals, visual, true), do: visuals ++ [visual]
  defp maybe_add_visual(visuals, _visual, _compatible?), do: visuals

  defp fetch_slug(attrs) do
    attrs
    |> fetch_string([:slug, "slug"])
    |> case do
      nil -> nil
      slug -> slugify(slug)
    end
  end

  defp slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> nil
      slug -> slug
    end
  end

  defp fetch_string(map, keys) when is_map(map) do
    map
    |> fetch_value(keys)
    |> normalize_string()
  end

  defp fetch_string(_map, _keys), do: nil

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(_value), do: nil

  defp fetch_map(map, keys) when is_map(map) do
    case fetch_value(map, keys) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp fetch_map(_map, _keys), do: nil

  defp fetch_integer(map, keys) when is_map(map) do
    case fetch_value(map, keys) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {int, ""} -> int
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp fetch_integer(_map, _keys), do: nil

  defp fetch_boolean(map, keys) when is_map(map) do
    case fetch_value(map, keys) do
      value when is_boolean(value) -> value
      value when is_binary(value) -> String.downcase(String.trim(value)) in ~w(true 1 yes on)
      _ -> nil
    end
  end

  defp fetch_boolean(_map, _keys), do: nil

  defp fetch_datetime(map, keys) when is_map(map) do
    case fetch_value(map, keys) do
      %DateTime{} = value ->
        value

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} -> dt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp fetch_datetime(_map, _keys), do: nil

  defp fetch_recipients(map) when is_map(map) do
    case fetch_value(map, [:recipients, "recipients"]) do
      values when is_list(values) ->
        values
        |> Enum.map(&normalize_string/1)
        |> Enum.reject(&is_nil/1)

      value when is_binary(value) ->
        value
        |> String.split([",", "\n"], trim: true)
        |> Enum.map(&normalize_string/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        nil
    end
  end

  defp fetch_recipients(_map), do: nil

  defp fetch_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.reduce_while(keys, nil, fn key, _acc ->
      if Map.has_key?(map, key) do
        {:halt, Map.get(map, key)}
      else
        {:cont, nil}
      end
    end)
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp normalize_existing_atom(value, allowed) when is_atom(value) do
    if value in allowed, do: value
  end

  defp normalize_existing_atom(value, allowed) when is_binary(value) do
    Enum.find(allowed, &(Atom.to_string(&1) == value))
  end

  defp normalize_existing_atom(_value, _allowed), do: nil

  defp normalize_existing_atoms(nil, _allowed), do: []

  defp normalize_existing_atoms(values, allowed) when is_list(values) do
    values
    |> Enum.map(&normalize_existing_atom(&1, allowed))
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_existing_atoms(value, allowed), do: normalize_existing_atoms([value], allowed)

  defp normalize_limit(value) when is_integer(value), do: value |> max(1) |> min(@max_limit)

  defp normalize_limit(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> normalize_limit(int)
      _ -> @default_limit
    end
  end

  defp normalize_limit(_value), do: @default_limit

  defp visual_types do
    Enum.map(@visuals, & &1.type)
  end

  defp owner_id(%{user: %{id: id}}), do: id
  defp owner_id(_scope), do: nil

  defp normalize_timezone(value) when value in ["UTC", "Etc/UTC"], do: "Etc/UTC"
  defp normalize_timezone(value) when is_binary(value) and value != "", do: value
  defp normalize_timezone(_value), do: @default_timezone

  defp present?(value), do: value not in [nil, ""]

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
