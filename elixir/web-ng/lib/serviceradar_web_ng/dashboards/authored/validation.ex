# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule ServiceRadarWebNG.Dashboards.Authored.Validation do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      require Ash.Query

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

      defp validate_visual_type(type) do
        if type in visual_types() do
          :ok
        else
          {:error, {:unsupported_visual_type, type}}
        end
      end

      # Tables are the catch-all rendering path for any tabular SRQL result shape.
      defp validate_visual_compatibility(:table, _compatible), do: :ok

      defp validate_visual_compatibility(type, compatible) do
        if type in compatible do
          :ok
        else
          {:error, {:incompatible_visual_type, type, compatible}}
        end
      end

      defp validate_data_binding(:availability, binding, fields) when is_map(binding) do
        if ServiceRadarWebNG.Dashboards.Authored.Visuals.grouped_availability_binding?(binding, fields) do
          validate_optional_bindings(binding, fields)
        else
          with :ok <- validate_required_binding(binding, fields, "numerator_field"),
               :ok <- validate_required_binding(binding, fields, "denominator_field") do
            validate_optional_bindings(binding, fields)
          end
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

      defp validate_panel_refresh_interval(value) when is_integer(value) and value >= 0 and value <= 86_400 do
        :ok
      end

      defp validate_panel_refresh_interval(value) do
        {:error, {:invalid_refresh_interval_seconds, value, 0, 86_400}}
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
             :ok <- validate_timezone(Map.get(attrs, :timezone, "UTC")) do
          {:ok, attrs}
        end
      end

      defp validate_recipients(recipients) when is_list(recipients) do
        cond do
          recipients == [] ->
            {:error, :report_schedule_recipients_required}

          length(recipients) > 50 ->
            {:error, {:too_many_report_recipients, length(recipients), 50}}

          invalid = Enum.find(recipients, &(not valid_email?(&1))) ->
            {:error, {:invalid_report_recipient, invalid}}

          true ->
            :ok
        end
      end

      defp validate_recipients(value), do: {:error, {:invalid_report_recipients, value}}

      defp validate_cron(cron) when is_binary(cron) do
        case Oban.Cron.Expression.parse(cron) do
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

      defp existing_panel_attrs(%ServiceRadar.Dashboards.DashboardPanel{} = panel) do
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

      defp existing_schedule_attrs(%ServiceRadar.Dashboards.DashboardReportSchedule{} = schedule) do
        %{
          dashboard_id: schedule.dashboard_id,
          name: schedule.name,
          enabled: schedule.enabled,
          recipients: schedule.recipients || [],
          cron: schedule.cron,
          timezone: schedule.timezone || "UTC",
          format: schedule.format || :html,
          next_due_at: schedule.next_due_at,
          metadata: schedule.metadata || %{}
        }
      end
    end
  end
end
