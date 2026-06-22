defmodule ServiceRadarWebNG.Dashboards.Authored.DashboardCrud do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      alias ServiceRadar.Dashboards.AuthoredDashboard

      require Ash.Query

      def create_dashboard(scope, attrs) when is_map(attrs) do
        with {:ok, attrs} <- validate_dashboard_attrs(dashboard_attrs(attrs)) do
          create_dashboard_with_ref(scope, attrs, 0)
        end
      end

      def create_dashboard(_scope, _attrs), do: {:error, :invalid_attributes}

      @spec create_dashboard_with_panels(term(), map(), [map()]) ::
              {:ok, {AuthoredDashboard.t(), [ServiceRadar.Dashboards.DashboardPanel.t()]}} | {:error, term()}
      def create_dashboard_with_panels(scope, attrs, panel_attrs) when is_map(attrs) and is_list(panel_attrs) do
        with {:ok, attrs} <- validate_dashboard_attrs(dashboard_attrs(attrs)) do
          case ServiceRadar.Repo.transaction(fn ->
                 with {:ok, dashboard, dashboard_notifications} <-
                        create_dashboard_with_ref_and_notifications(scope, attrs, 0),
                      {:ok, panels, panel_notifications} <-
                        create_panels_for_dashboard_with_notifications(scope, dashboard, panel_attrs) do
                   {dashboard, panels, dashboard_notifications ++ panel_notifications}
                 else
                   {:error, reason} -> ServiceRadar.Repo.rollback(reason)
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
        1_000_000 + :rand.uniform(9_999_999 - 1_000_000 + 1) - 1
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
    end
  end
end
