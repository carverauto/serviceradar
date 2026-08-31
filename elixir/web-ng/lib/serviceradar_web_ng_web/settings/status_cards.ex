defmodule ServiceRadarWebNGWeb.Settings.StatusCards do
  @moduledoc """
  Resolves the **contextual** status-card strip for the catalog Settings shell.

  `for_view/1` picks a card set appropriate to the active page, resolving from
  the view → its parent-group → its category, so cluster-health cards never leak
  onto a Network or Edge page. When a page renders its own metric cards
  (`has_own_stats: true`, e.g. Cluster Status with its Oban queue table) the whole
  strip is suppressed (`:suppressed`).

  Every metric is computed independently and fails soft to `nil`, so a single
  unavailable source degrades only its own card to `"—"` (see
  `ServiceRadarWebNGWeb.Settings.Shell`, which renders a `nil` value as an em
  dash). Each metric is wired to the same authoritative source the corresponding
  page reads from (agent/user/device/sweep/audit resources), resolved with cheap
  aggregate counts rather than per-row queries.
  """

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Edge.AgentRelease
  alias ServiceRadar.Identity.OAuthClient
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Repo
  alias ServiceRadar.Security.AuditHistory
  alias ServiceRadar.Security.SecurityEvent
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadarWebNG.TenantUsage
  alias ServiceRadarWebNGWeb.Settings.Catalog
  alias ServiceRadarWebNGWeb.Stats

  require Ash.Query

  # Counts are computed unscoped (`authorize?: false`): the status strip is an
  # operator-facing summary and each resolver is wrapped fail-soft below, so a
  # missing/unauthorized/unavailable source only dashes its own card.
  #
  # A card MAY carry an optional `:navigate` destination (an internal LiveView
  # route). When present, the shell renders that card as a link to the page that
  # manages the underlying resource; cards without it render as plain metrics.
  @type card :: %{
          required(:title) => String.t(),
          required(:value) => term() | nil,
          optional(:navigate) => String.t()
        }

  @doc """
  The contextual status cards for a view, or `:suppressed` when the page renders
  its own metrics.
  """
  @spec for_view(map() | nil, term()) :: :suppressed | [card()]
  def for_view(view, scope \\ nil)
  def for_view(%{has_own_stats: true}, _scope), do: :suppressed
  def for_view(%{} = view, scope), do: view |> context_for() |> cards() |> filter_cards(scope)
  def for_view(_, _scope), do: []

  # Resolve a card-set context from the view. Audit-flavoured views get an audit
  # set; otherwise resolve by parent-group, then by category.
  defp context_for(%{id: id}) when id in [:audit_trail, :lockouts, :history], do: :audit
  defp context_for(%{parent_group: :sys_cluster}), do: :cluster
  defp context_for(%{parent_group: :sys_security}), do: :users
  defp context_for(%{parent_group: :sys_alerts}), do: :alerts
  defp context_for(%{category: :network_services}), do: :network
  defp context_for(%{category: :edge_ops}), do: :edge
  defp context_for(_), do: :cluster

  defp cards(:cluster) do
    [
      %{title: "Cluster health", value: cluster_health()},
      %{title: "Connected agents", value: connected_agents()},
      %{title: "Pending jobs", value: pending_jobs()},
      %{title: "Active alerts", value: active_alerts()}
    ]
  end

  # The users/access strip. Each count links to the page that manages that
  # resource: the user-population cards open Users management, the API-key card
  # opens API Credentials when the scope holds settings.api_credentials.manage.
  defp cards(:users) do
    [
      %{title: "Total users", value: total_users(), navigate: "/settings/auth/users"},
      %{title: "Active (30d)", value: active_users_30d(), navigate: "/settings/auth/users"},
      %{title: "Admins", value: admin_users(), navigate: "/settings/auth/users"},
      %{title: "API keys", value: api_credentials_count(), navigate: "/settings/api-credentials"}
    ]
  end

  defp cards(:audit) do
    [
      %{title: "Audit events (24h)", value: audit_events_24h()},
      %{title: "Config changes", value: config_changes_24h()}
    ]
  end

  defp cards(:alerts) do
    [
      %{title: "Active alerts", value: active_alerts()},
      %{title: "Pending jobs", value: pending_jobs()}
    ]
  end

  defp cards(:network) do
    [
      %{title: "Discovered devices", value: discovered_devices()},
      %{title: "Active sweeps", value: active_sweeps()}
    ]
  end

  defp cards(:edge) do
    [
      %{title: "Total agents", value: connected_agents()},
      %{title: "Online", value: reporting_agents()},
      %{title: "Add-ons", value: addon_packages_count()},
      %{title: "Latest release", value: latest_release()}
    ]
  end

  defp filter_cards(cards, nil), do: cards

  defp filter_cards(cards, scope) do
    Enum.filter(cards, fn
      %{navigate: "/settings/api-credentials"} ->
        case Catalog.view(:api_credentials) do
          nil -> false
          view -> Catalog.visible_view?(scope, view)
        end

      _card ->
        true
    end)
  end

  # ---------------------------------------------------------------------------
  # Metric resolvers — each never raises; degrades to nil.
  # ---------------------------------------------------------------------------

  defp cluster_health do
    status = ServiceRadar.Cluster.ClusterStatus.get_status()
    if status.enabled, do: "Active", else: "Standalone"
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Total connected agents — the same authoritative source the Agent Releases page
  # counts for "Connected agents available now" (`Agent`'s `:connected` read:
  # status connected + healthy + seen in the last 30m). Replaces the old
  # `AgentTracker` RPC, which reported 0 on single-node deployments.
  defp connected_agents do
    Agent
    |> Ash.Query.for_read(:connected, %{})
    |> Ash.count!(authorize?: false)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # A distinct, tighter "reporting" count: agents seen in the last 5 minutes.
  defp reporting_agents do
    Agent
    |> Ash.Query.for_read(:recently_seen, %{})
    |> Ash.count!(authorize?: false)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # The product version comes from the immutable image tag Helm deployed. The
  # AgentRelease table describes downloadable agent artifacts and can lag the
  # running control plane, so it is only a local-development fallback.
  defp latest_release do
    case deployed_release_version() do
      nil -> latest_agent_release()
      version -> version
    end
  end

  defp deployed_release_version do
    case System.get_env("SERVICERADAR_RELEASE_VERSION") do
      version when is_binary(version) ->
        case String.trim(version) do
          "" -> nil
          "v" <> semver -> semver
          tag -> tag
        end

      _ ->
        nil
    end
  end

  defp latest_agent_release do
    AgentRelease
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.sort(published_at: :desc, inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [%{version: version} | _] when is_binary(version) and version != "" -> version
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Count of add-on packages in the catalog (the Add-ons Catalog page lists these).
  defp addon_packages_count do
    AddonPackage
    |> Ash.Query.for_read(:read, %{})
    |> Ash.count!(authorize?: false)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp total_users do
    User
    |> Ash.Query.for_read(:read, %{})
    |> Ash.count!(authorize?: false)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Users active in the last 30 days, counted by the SAME field the Users page
  # renders in its "Last Activity" column — `coalesce(last_login_at,
  # authenticated_at)` (see AuthUsersLive.format_last_activity/1). The web login
  # flows only call `User.record_authentication` (sets `authenticated_at`); none
  # call `User.record_login` (the only writer of `last_login_at`), so
  # `last_login_at` is empty and filtering on it alone always returned 0. We now
  # count a user active when EITHER activity timestamp falls in the window.
  defp active_users_30d do
    cutoff = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)

    User
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(last_login_at >= ^cutoff or authenticated_at >= ^cutoff)
    |> Ash.count!(authorize?: false)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Count of admin accounts — users with role :admin and status :active — via the
  # User resource's `:admins` read (the same criterion AuthUsersLive uses for its
  # active-admin count). Non-overlapping with the "Active (30d)" activity card.
  defp admin_users do
    User
    |> Ash.Query.for_read(:admins, %{})
    |> Ash.count!(authorize?: false)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Count of API credential clients (the API Credentials page manages these).
  defp api_credentials_count do
    OAuthClient
    |> Ash.Query.for_read(:read, %{})
    |> Ash.count!(authorize?: false)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Managed+active devices — the canonical runtime device count (also drives
  # plan/usage visibility). `managed_device_count/0` fails soft to 0 itself.
  defp discovered_devices do
    TenantUsage.managed_device_count()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Enabled sweep groups (the Sweep Profiles / Discovery page manages these).
  defp active_sweeps do
    SweepGroup
    |> Ash.Query.for_read(:enabled_groups, %{})
    |> Ash.count!(authorize?: false)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Security events recorded in the last 24h. The Audit → Events page live-tails
  # these over PubSub but also reads them from the `security_events` table, so a
  # windowed count is a real value here.
  defp audit_events_24h do
    cutoff = DateTime.add(DateTime.utc_now(), -24 * 3600, :second)

    SecurityEvent
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(occurred_at >= ^cutoff)
    |> Ash.count!(authorize?: false)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # AshPaperTrail version rows written in the last 24h, summed across the same
  # resource allow-list the Audit → History page reads from.
  defp config_changes_24h do
    cutoff = DateTime.add(DateTime.utc_now(), -24 * 3600, :second)

    AuditHistory.resources()
    |> Enum.map(&count_versions_since(&1, cutoff))
    |> Enum.sum()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Mirror `AuditHistory.list_recent/1`'s per-resource `read_versions/6`: it
  # isolates every resource behind a `rescue -> []` and treats `{:error, _}` as
  # empty, so one resource whose `<Resource>.Version` table is unavailable (e.g.
  # not migrated on this deployment, or an RBAC/read failure) is dropped rather
  # than crashing the whole timeline. The previous unwrapped `Ash.count!` here
  # let a single such failure bubble up to `config_changes_24h`'s outer rescue,
  # dashing the entire card. Now each resource contributes its real count, or 0
  # when its versions can't be read — never nil — so a genuine 0 renders as 0.
  defp count_versions_since(resource, cutoff) do
    version_module = Module.concat(resource, Version)

    if Code.ensure_loaded?(version_module) do
      version_module
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(version_inserted_at >= ^cutoff)
      |> Ash.count(authorize?: false)
      |> case do
        {:ok, count} -> count
        _ -> 0
      end
    else
      0
    end
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end

  defp pending_jobs do
    query =
      from(j in Oban.Job,
        where: j.state in ["available", "scheduled", "retryable"],
        select: count(j.id)
      )

    Repo.one(query) || 0
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp active_alerts do
    summary = Stats.alerts_summary()
    (summary[:pending] || 0) + (summary[:escalated] || 0)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
