defmodule ServiceRadar.Security.SecurityEvent do
  @moduledoc """
  Append-only event log for stateless security signals that have no
  natural resource version: failed logins, rate-limit denials, policy
  denials, signature failures, lockout triggers/clears, CSP violation
  reports.

  Resources that already use AshPaperTrail (credentials, ansible
  playbooks, console sessions, the new `WebhookSecret`) continue to
  carry their own version history. This resource is for events that
  don't map to a row mutation.
  """

  use Ash.Resource,
    domain: ServiceRadar.Security,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @kinds [
    :login_failed,
    :rate_limit_denied,
    :policy_denied,
    :lockout_triggered,
    :lockout_cleared,
    :csp_violation,
    :edge_onboarding_succeeded,
    :edge_onboarding_failed,
    :mcp_auth_failed,
    :mcp_session_initialized,
    :mcp_tool_called,
    :mcp_tool_denied,
    :mcp_oauth_authorize_approved,
    :mcp_oauth_authorize_denied,
    :mcp_oauth_token_issued,
    :mcp_oauth_refreshed,
    :mcp_oauth_refresh_reuse,
    :mcp_oauth_grant_revoked,
    :mcp_oauth_idp_refresh_denied,
    :mcp_oauth_slo_revoked,
    :other
  ]

  @severities [:info, :warning, :critical]

  def kinds, do: @kinds
  def severities, do: @severities

  postgres do
    table "security_events"
    repo ServiceRadar.Repo
    schema "platform"

    custom_indexes do
      index [:occurred_at], using: "BRIN"
      index [:kind, :occurred_at]
    end
  end

  code_interface do
    define :list, action: :read
    define :record, action: :create
    define :delete_older_than, action: :delete_older_than, args: [:cutoff]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :occurred_at,
        :kind,
        :severity,
        :actor_id,
        :ip,
        :route,
        :details,
        :correlation_id
      ]

      change fn changeset, _ctx ->
        if Ash.Changeset.get_attribute(changeset, :occurred_at) do
          changeset
        else
          Ash.Changeset.force_change_attribute(
            changeset,
            :occurred_at,
            DateTime.utc_now()
          )
        end
      end
    end

    action :delete_older_than, :map do
      argument :cutoff, :utc_datetime_usec, allow_nil?: false

      run fn input, _ctx ->
        ServiceRadar.Security.SecurityEvent.Retention.run(
          input.arguments.cutoff,
          actor: input.context[:private][:actor]
        )
      end
    end
  end

  policies do
    import ServiceRadar.Policies

    alias ServiceRadar.Policies.Checks.ActorHasPermission

    @audit_view {ActorHasPermission, permission: "settings.audit.view"}
    @audit_manage {ActorHasPermission, permission: "settings.audit.manage"}

    system_bypass()

    action_type_with_permission(:read, @audit_view)
    # Direct create/destroy from a user actor is unusual — SystemActor is
    # the platform writer. Gate on audit.manage anyway as defense in depth.
    action_type_with_permission([:create, :update, :destroy], @audit_manage)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :occurred_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: @kinds
    end

    attribute :severity, :atom do
      allow_nil? false
      default :info
      public? true
      constraints one_of: @severities
    end

    attribute :actor_id, :string do
      allow_nil? true
      public? true
    end

    attribute :ip, :string do
      allow_nil? true
      public? true
      constraints max_length: 64
    end

    attribute :route, :string do
      allow_nil? true
      public? true
      constraints max_length: 256
    end

    attribute :details, :map do
      allow_nil? true
      default %{}
      public? true
    end

    attribute :correlation_id, :string do
      allow_nil? true
      public? true
      constraints max_length: 128
    end

    timestamps()
  end
end
