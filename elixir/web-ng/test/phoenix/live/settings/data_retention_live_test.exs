defmodule ServiceRadarWebNGWeb.Settings.DataRetentionLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.Socket
  alias ServiceRadar.Analytics.StarRocks.Retention
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Catalog
  alias ServiceRadarWebNGWeb.Settings.DataRetentionLive
  alias ServiceRadarWebNGWeb.Settings.StatusCards

  @moduletag :db_free

  setup do
    if !Process.whereis(ServiceRadarWebNGWeb.Endpoint) do
      start_supervised!(ServiceRadarWebNGWeb.Endpoint)
    end

    :ok
  end

  defp admin_scope do
    %Scope{
      user: %{id: "user-1", email: "admin@example.com", timezone: "America/Chicago"},
      permissions: MapSet.new(["settings.data_retention.view", "settings.data_retention.manage"])
    }
  end

  defp viewer_scope do
    %Scope{
      user: %{id: "user-2", email: "viewer@example.com", timezone: "America/Chicago"},
      permissions: MapSet.new(["settings.data_retention.view"])
    }
  end

  defp sample_entry(dataset) do
    sample_entry(dataset, [])
  end

  defp sample_entry(dataset, opts) do
    defaults = %{
      dataset: dataset,
      tables: Retention.tables_for(dataset),
      days: Keyword.get(opts, :days, 365),
      stored?: Keyword.get(opts, :stored?, true),
      seed_days: 365,
      default_days: Retention.default_days(dataset),
      min_days: Retention.min_days(dataset),
      min_partitions: Retention.min_partitions(dataset),
      storage_warning?: false,
      updated_by: Keyword.get(opts, :updated_by, "admin@example.com"),
      updated_at: Keyword.get(opts, :updated_at, ~U[2026-10-08 12:00:00Z]),
      inserted_at: Keyword.get(opts, :inserted_at, ~U[2026-10-08 10:00:00Z]),
      last_applied_days: Keyword.get(opts, :last_applied_days, 365),
      last_applied_status: Keyword.get(opts, :last_applied_status, "applied"),
      last_applied_error: Keyword.get(opts, :last_applied_error, nil),
      last_applied_at: Keyword.get(opts, :last_applied_at, ~U[2026-10-08 12:00:05Z])
    }

    Map.merge(defaults, Map.new(opts))
  end

  defp base_assigns do
    base_assigns([])
  end

  defp base_assigns(opts) do
    scope = Keyword.get(opts, :scope, admin_scope())
    path = "/settings/data-retention"
    view = Catalog.view_for_path(path)
    category = Catalog.category_for_view(view)

    %{
      flash: %{},
      current_path: path,
      current_scope: scope,
      can_manage?: Keyword.get(opts, :can_manage?, RBAC.can?(scope, "settings.data_retention.manage")),
      warehouse_enabled?: Keyword.get(opts, :warehouse_enabled?, true),
      entries: Keyword.get(opts, :entries, []),
      drafts: %{},
      errors: %{},
      load_error: nil,
      has_pending?: Keyword.get(opts, :has_pending?, false),
      has_stale_pending?: Keyword.get(opts, :has_stale_pending?, false),
      now: Keyword.get(opts, :now, DateTime.utc_now()),
      applier_health:
        Keyword.get(opts, :applier_health, %{
          running?: false,
          node: nil,
          last_reconciled_at: nil,
          last_outcome: nil
        }),
      settings_active_view: view,
      settings_active_category: category,
      settings_breadcrumbs: Catalog.breadcrumbs_for_path(path),
      settings_nav_tree: %{
        categories: Catalog.visible_categories(scope),
        groups: Catalog.nav_tree(scope, category.id)
      },
      settings_palette: Catalog.palette_index(scope),
      settings_stats: StatusCards.for_view(view)
    }
  end

  defp new_socket do
    new_socket([])
  end

  defp new_socket(opts) do
    scope = Keyword.get(opts, :scope, admin_scope())

    %Socket{
      endpoint: ServiceRadarWebNGWeb.Endpoint,
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            flash: %{},
            current_scope: scope
          },
          Map.new(opts)
        )
    }
  end

  describe "pending age calculation and formatting" do
    test "format_age formats seconds cleanly" do
      assert DataRetentionLive.format_age(0) == "< 1m"
      assert DataRetentionLive.format_age(45) == "< 1m"
      assert DataRetentionLive.format_age(60) == "1m"
      assert DataRetentionLive.format_age(125) == "2m"
      assert DataRetentionLive.format_age(3600) == "1h"
      assert DataRetentionLive.format_age(3720) == "1h 2m"
      assert DataRetentionLive.format_age(-5) == nil
      assert DataRetentionLive.format_age(nil) == nil
    end

    test "pending_age_seconds calculates duration from updated_at or inserted_at" do
      now = ~U[2026-10-08 12:10:00Z]
      updated_at = ~U[2026-10-08 12:05:00Z]
      inserted_at = ~U[2026-10-08 12:00:00Z]

      pending_entry =
        sample_entry(:flows,
          last_applied_status: "pending",
          updated_at: updated_at,
          inserted_at: inserted_at
        )

      assert DataRetentionLive.pending_age_seconds(pending_entry, now) == 300

      pending_no_updated =
        sample_entry(:flows,
          last_applied_status: "pending",
          updated_at: nil,
          inserted_at: inserted_at
        )

      assert DataRetentionLive.pending_age_seconds(pending_no_updated, now) == 600

      applied_entry =
        sample_entry(:flows,
          last_applied_status: "applied",
          updated_at: updated_at
        )

      assert DataRetentionLive.pending_age_seconds(applied_entry, now) == nil
    end

    test "stale_pending? triggers at or after 300 seconds" do
      now = ~U[2026-10-08 12:05:00Z]

      fresh_entry =
        sample_entry(:flows,
          last_applied_status: "pending",
          updated_at: ~U[2026-10-08 12:01:00Z]
        )

      refute DataRetentionLive.stale_pending?(fresh_entry, now)

      stale_entry =
        sample_entry(:flows,
          last_applied_status: "pending",
          updated_at: ~U[2026-10-08 11:59:00Z]
        )

      assert DataRetentionLive.stale_pending?(stale_entry, now)
    end
  end

  describe "applier health display" do
    test "renders applier running with node and last reconciled details" do
      reconciled_at = ~U[2026-10-08 12:00:00Z]

      assigns =
        base_assigns(
          applier_health: %{
            running?: true,
            node: :"core@node1.internal",
            last_reconciled_at: reconciled_at,
            last_outcome: :ok
          }
        )

      html = rendered_to_string(DataRetentionLive.render(assigns))

      assert html =~ "Applier running"
      assert html =~ "core@node1.internal"
      assert html =~ "(ok)"
      refute html =~ "No applier running"
      refute html =~ "id=\"retention-no-applier-alert\""
    end

    test "renders no applier running alert when applier is not active" do
      assigns =
        base_assigns(
          applier_health: %{
            running?: false,
            node: nil,
            last_reconciled_at: nil,
            last_outcome: nil
          }
        )

      html = rendered_to_string(DataRetentionLive.render(assigns))

      assert html =~ "No applier running"
      assert html =~ "id=\"retention-no-applier-alert\""
      assert html =~ "No ServiceRadar core instance is currently running the retention applier"
    end
  end

  describe "warehouse disabled handling" do
    test "displays disabled alert, disables Save, and shows unavailable status instead of pending" do
      entry =
        sample_entry(:flows,
          last_applied_status: "pending",
          updated_at: ~U[2026-10-08 12:00:00Z]
        )

      assigns =
        base_assigns(
          warehouse_enabled?: false,
          entries: [entry]
        )

      html = rendered_to_string(DataRetentionLive.render(assigns))

      assert html =~ "id=\"retention-warehouse-disabled\""
      assert html =~ "Data retention is unavailable because StarRocks analytics is disabled"
      assert html =~ "analytics.starrocks.enabled: true"
      assert html =~ "unavailable"
      assert html =~ "StarRocks warehouse is disabled"
      refute html =~ "pending"

      doc = LazyHTML.from_fragment(html)
      save_btn = LazyHTML.query(doc, "#retention-form-flows button[type='submit']")
      assert LazyHTML.attribute(save_btn, "disabled") == [""]
    end

    test "saving while warehouse is disabled sets an error flash" do
      socket =
        new_socket(
          warehouse_enabled?: false,
          can_manage?: true
        )

      assert {:noreply, updated_socket} =
               DataRetentionLive.handle_event(
                 "save",
                 %{"dataset" => "flows", "days" => "90"},
                 socket
               )

      assert updated_socket.assigns.flash["error"] =~
               "Data retention is unavailable because the StarRocks warehouse is disabled"
    end
  end

  describe "viewer role" do
    test "viewer renders retention in read-only mode without save forms" do
      assigns =
        base_assigns(
          scope: viewer_scope(),
          can_manage?: false,
          entries: [sample_entry(:flows)]
        )

      html = rendered_to_string(DataRetentionLive.render(assigns))
      assert html =~ "365 days"
      refute html =~ "retention-form-flows"
    end
  end

  describe "stale pending warning" do
    test "renders page-level and row-level warning for stale pending rows" do
      now = ~U[2026-10-08 12:15:00Z]
      stale_updated_at = ~U[2026-10-08 12:00:00Z]

      stale_entry =
        sample_entry(:flows,
          last_applied_status: "pending",
          updated_at: stale_updated_at
        )

      assigns =
        base_assigns(
          now: now,
          has_stale_pending?: true,
          entries: [stale_entry]
        )

      html = rendered_to_string(DataRetentionLive.render(assigns))

      assert html =~ "id=\"retention-stale-pending-alert\""
      assert html =~ "One or more retention settings have been pending for more than 5 minutes"
      assert html =~ "warehouse is unreachable, a schema change is in progress"
      assert html =~ "id=\"retention-flows-stale-warning\""
      assert html =~ "Pending over 5m"
      assert html =~ "(for 15m)"
    end

    test "tableless pending dataset is not stale" do
      now = ~U[2026-10-08 12:15:00Z]

      tableless =
        sample_entry(:flows,
          last_applied_status: "pending",
          updated_at: ~U[2026-10-08 12:00:00Z],
          tables: [],
          stored?: true
        )

      refute DataRetentionLive.stale_pending?(tableless, now)

      unstored =
        sample_entry(:flows,
          last_applied_status: "pending",
          updated_at: ~U[2026-10-08 12:00:00Z],
          stored?: false
        )

      refute DataRetentionLive.stale_pending?(unstored, now)

      socket =
        new_socket(
          can_manage?: true,
          warehouse_enabled?: true,
          entries_override: [tableless],
          applier_health_override: %{running?: true, node: nil, last_reconciled_at: nil, last_outcome: nil}
        )

      {:ok, socket} = DataRetentionLive.mount(%{}, %{}, socket)
      refute socket.assigns.has_pending?
      refute socket.assigns.has_stale_pending?

      assigns = Map.merge(base_assigns(now: now, entries: [tableless]), socket.assigns)
      html = rendered_to_string(DataRetentionLive.render(assigns))
      refute html =~ "id=\"retention-flows-stale-warning\""
      refute html =~ "id=\"retention-stale-pending-alert\""
    end
  end

  describe "LiveView saved transitions" do
    test "saved, no applier: shows no applier warning and does not poll silently" do
      initial_entry = sample_entry(:flows, days: 365, last_applied_status: "applied")

      saved_entry =
        sample_entry(:flows,
          days: 90,
          last_applied_status: "pending",
          updated_at: DateTime.utc_now()
        )

      saved_flag = :atomics.new(1, [])

      save_fn = fn "flows", 90 ->
        :atomics.put(saved_flag, 1, 1)
        {:ok, %{dataset: "flows", days: 90}}
      end

      entries_override = fn ->
        if :atomics.get(saved_flag, 1) == 1 do
          [saved_entry]
        else
          [initial_entry]
        end
      end

      # Applier is NOT running
      applier_health = %{running?: false, node: nil, last_reconciled_at: nil, last_outcome: nil}

      socket =
        new_socket(
          can_manage?: true,
          warehouse_enabled?: true,
          entries_override: entries_override.(),
          applier_health_override: applier_health,
          save_fn: save_fn
        )

      # 1. Mount socket
      {:ok, socket} = DataRetentionLive.mount(%{}, %{}, socket)
      assert socket.assigns.can_manage?
      refute socket.assigns.applier_health.running?

      # 2. Save retention days to 90
      socket = assign(socket, :entries_override, [saved_entry])

      {:noreply, socket} =
        DataRetentionLive.handle_event(
          "save",
          %{"dataset" => "flows", "days" => "90"},
          socket
        )

      assert socket.assigns.flash["info"] =~ "Saved Network flows retention"
      assert socket.assigns.has_pending?

      # 3. Because applier is not running, silent polling was NOT scheduled
      refute_received :refresh

      # 4. Render HTML verifies "No retention applier is running" warning and pending status
      assigns =
        Map.merge(
          base_assigns(
            applier_health: applier_health,
            entries: socket.assigns.entries,
            has_pending?: socket.assigns.has_pending?
          ),
          socket.assigns
        )

      html = rendered_to_string(DataRetentionLive.render(assigns))
      assert html =~ "id=\"retention-no-applier-alert\""
      assert html =~ "No retention applier is running"
      assert html =~ "pending"
      assert html =~ "for &lt; 1m"
    end

    test "saved, applied: badge flips to applied" do
      initial_entry = sample_entry(:flows, days: 365, last_applied_status: "applied")

      pending_entry =
        sample_entry(:flows,
          days: 90,
          last_applied_status: "pending",
          updated_at: DateTime.utc_now()
        )

      applied_entry =
        sample_entry(:flows,
          days: 90,
          last_applied_status: "applied",
          last_applied_days: 90,
          last_applied_at: DateTime.utc_now()
        )

      applier_health = %{
        running?: true,
        node: :core@node1,
        last_reconciled_at: DateTime.utc_now(),
        last_outcome: :ok
      }

      save_fn = fn "flows", 90 ->
        {:ok, %{dataset: "flows", days: 90}}
      end

      socket =
        new_socket(
          can_manage?: true,
          warehouse_enabled?: true,
          entries_override: [initial_entry],
          applier_health_override: applier_health,
          save_fn: save_fn
        )

      # 1. Mount with running applier
      {:ok, socket} = DataRetentionLive.mount(%{}, %{}, socket)
      assert socket.assigns.can_manage?
      assert socket.assigns.applier_health.running?

      # 2. Save retention days to 90 -> entry becomes pending
      socket = assign(socket, :entries_override, [pending_entry])

      {:noreply, socket} =
        DataRetentionLive.handle_event(
          "save",
          %{"dataset" => "flows", "days" => "90"},
          socket
        )

      assert socket.assigns.has_pending?
      pending = hd(socket.assigns.entries)
      assert pending.last_applied_status == "pending"

      assigns_pending =
        Map.merge(
          base_assigns(
            applier_health: applier_health,
            entries: socket.assigns.entries,
            has_pending?: true
          ),
          socket.assigns
        )

      html_pending = rendered_to_string(DataRetentionLive.render(assigns_pending))
      assert html_pending =~ "pending"
      assert html_pending =~ "for &lt; 1m"

      # 3. Applier reconciles and broadcasts change -> entry becomes applied
      socket = assign(socket, :entries_override, [applied_entry])

      {:noreply, socket} =
        DataRetentionLive.handle_info({:warehouse_retention_changed, "flows"}, socket)

      # 4. Entry is now applied and badge flips to applied
      refute socket.assigns.has_pending?
      applied = hd(socket.assigns.entries)
      assert applied.last_applied_status == "applied"
      assert applied.last_applied_days == 90

      assigns_applied =
        Map.merge(
          base_assigns(
            applier_health: applier_health,
            entries: socket.assigns.entries,
            has_pending?: false
          ),
          socket.assigns
        )

      html_applied = rendered_to_string(DataRetentionLive.render(assigns_applied))
      assert html_applied =~ "applied"
      assert html_applied =~ "90 days"
      refute html_applied =~ "id=\"retention-no-applier-alert\""
    end
  end
end
