defmodule ServiceRadarWebNG.Dashboards.Authored.PanelsReports do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      alias ServiceRadar.Dashboards.DashboardPanel
      alias ServiceRadar.Dashboards.DashboardReportSchedule

      require Ash.Query

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

      defp create_panels_for_dashboard_with_notifications(
             scope,
             %ServiceRadar.Dashboards.AuthoredDashboard{} = dashboard,
             panel_attrs
           ) do
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
    end
  end
end
