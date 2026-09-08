defmodule ServiceRadarWebNG.Dashboards.Authored.Attrs do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      alias Oban.Cron.Expression

      require Ash.Query

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
        timezone = Map.get(attrs, :timezone) || "UTC"

        case next_due_at(cron, timezone, DateTime.utc_now()) do
          %DateTime{} = next_due_at -> Map.put(attrs, :next_due_at, next_due_at)
          _ -> attrs
        end
      end

      defp maybe_put_next_due_at(attrs), do: attrs

      @spec next_due_at(String.t(), String.t(), DateTime.t()) :: DateTime.t() | nil
      def next_due_at(cron, timezone \\ "UTC", after_time \\ DateTime.utc_now())

      def next_due_at(cron, timezone, %DateTime{} = after_time) when is_binary(cron) do
        with {:ok, expr} <- Expression.parse(cron),
             {:ok, base} <- DateTime.shift_zone(after_time, normalize_timezone(timezone)) do
          Expression.next_at(expr, base)
        else
          _ -> nil
        end
      end

      def next_due_at(_cron, _timezone, _after_time), do: nil
    end
  end
end
