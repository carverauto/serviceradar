defmodule ServiceRadarWebNG.Dashboards.Authored.Listing do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      alias ServiceRadar.Dashboards.AuthoredDashboard
      alias ServiceRadar.Dashboards.DashboardUserPreference

      require Ash.Query

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
    end
  end
end
