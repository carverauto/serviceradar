# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule ServiceRadarWebNG.Dashboards.Authored.Sharing do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      alias ServiceRadar.Dashboards.DashboardAccessGrant
      alias ServiceRadar.Identity.PrivilegedMembership
      alias ServiceRadar.Identity.User
      alias ServiceRadar.Identity.UserGroup
      alias ServiceRadar.Identity.UserGroupMembership
      alias ServiceRadarWebNG.Dashboards.GroupAccess

      require Ash.Query

      def list_report_deliveries(scope, dashboard_id) when is_binary(dashboard_id) do
        ServiceRadar.Dashboards.DashboardReportDelivery
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
          |> Map.put_new(:granted_by_id, owner_id(scope))

        DashboardAccessGrant
        |> Ash.Changeset.for_create(:create, attrs)
        |> create(scope)
      end

      def grant_dashboard_to_user(_scope, _attrs), do: {:error, :invalid_attributes}

      @spec grant_dashboard_to_group(term(), map()) ::
              {:ok, DashboardAccessGrant.t()} | {:error, term()}
      def grant_dashboard_to_group(scope, attrs) when is_map(attrs) do
        attrs = access_grant_attrs(attrs)

        with dashboard_id when is_binary(dashboard_id) <- Map.get(attrs, :dashboard_id),
             group_id when is_binary(group_id) <- Map.get(attrs, :subject_group_id),
             access when access in [:view, :edit] <- Map.get(attrs, :access),
             {:ok, %{grant: grant}} <-
               GroupAccess.set_group_access(
                 scope,
                 {:local, :authored},
                 dashboard_id,
                 group_id,
                 access,
                 metadata: Map.get(attrs, :metadata, %{})
               ) do
          {:ok, grant}
        else
          nil -> {:error, :invalid_attributes}
          {:error, _reason} = error -> error
        end
      end

      def grant_dashboard_to_group(_scope, _attrs), do: {:error, :invalid_attributes}

      @spec revoke_access_grant(term(), DashboardAccessGrant.t()) :: :ok | {:error, term()}
      def revoke_access_grant(scope, %DashboardAccessGrant{subject_type: :group} = grant) do
        case GroupAccess.revoke_group_access(
               scope,
               {:local, :authored},
               grant.dashboard_id,
               grant.subject_group_id
             ) do
          {:ok, _result} -> :ok
          {:error, _reason} = error -> error
        end
      end

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
        |> Ash.Query.filter(group_id: group_id)
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

      @spec add_user_group_member(term(), map()) ::
              {:ok, UserGroupMembership.t()} | {:error, term()}
      def add_user_group_member(scope, attrs) when is_map(attrs) do
        attrs = user_group_membership_attrs(attrs)

        PrivilegedMembership.add(
          scope,
          Map.get(attrs, :group_id),
          Map.get(attrs, :user_id),
          Map.take(attrs, [:role, :metadata])
        )
      end

      def add_user_group_member(_scope, _attrs), do: {:error, :invalid_attributes}

      @spec list_share_principals(term()) :: [User.t()]
      def list_share_principals(scope) do
        User
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(status: :active)
        |> Ash.Query.limit(500)
        |> Ash.Query.sort(email: :asc)
        |> read!(scope)
      end

      @spec visual_options() :: [map()]
      defdelegate visual_options, to: ServiceRadarWebNG.Dashboards.Authored.Visuals
    end
  end
end
