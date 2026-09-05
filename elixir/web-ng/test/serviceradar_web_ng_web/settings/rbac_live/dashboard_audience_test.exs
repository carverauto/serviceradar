defmodule ServiceRadarWebNGWeb.Settings.RbacLive.DashboardAudienceTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Settings.RbacLive.Components
  alias ServiceRadarWebNGWeb.Settings.RbacLive.DashboardAudience

  @moduletag :db_free

  @empty_source %{
    before: nil,
    after: nil,
    request_ref: nil,
    loading?: false,
    error: nil,
    expected: %{}
  }

  test "new state has no selected group and two empty source windows" do
    assert %{
             group_token: nil,
             group_id: nil,
             group_name: nil,
             epoch: 0,
             authored: @empty_source,
             package: @empty_source
           } = DashboardAudience.new()
  end

  test "selected group display metadata survives source activity for refresh rendering" do
    selected =
      DashboardAudience.select_group(
        DashboardAudience.new(),
        "group-token-a",
        "group-a",
        "Synthetic operations group"
      )

    assert selected.group_name == "Synthetic operations group"

    assert {:ok, requested, :first, 1} =
             DashboardAudience.start_request(selected, :authored, :first, "request-a")

    assert requested.group_name == "Synthetic operations group"
  end

  test "a refreshed token resyncs only for the still-selected group" do
    state = selected_state()

    assert {:ok, synced} =
             DashboardAudience.sync_group_token(state, "fresh-group-token", "group-a")

    assert synced.group_token == "fresh-group-token"
    assert synced.epoch == state.epoch
    assert synced.authored == state.authored
    assert synced.package == state.package

    assert {:error, :stale} =
             DashboardAudience.sync_group_token(state, "other-group-token", "group-b")
  end

  test "selecting a group increments the epoch and clears both source windows" do
    state = %{
      group_token: "old-group-token",
      group_id: "group-a",
      group_name: "Synthetic old group",
      epoch: 7,
      authored: %{
        @empty_source
        | before: "authored-before",
          after: "authored-after",
          expected: %{"row-a" => %{target_id: "authored-a"}}
      },
      package: %{
        @empty_source
        | before: "package-before",
          after: "package-after",
          expected: %{"row-b" => %{target_id: "package-a"}}
      }
    }

    next =
      DashboardAudience.select_group(
        state,
        "new-group-token",
        "group-b",
        "Synthetic replacement group"
      )

    assert next.group_token == "new-group-token"
    assert next.group_id == "group-b"
    assert next.group_name == "Synthetic replacement group"
    assert next.epoch == 8
    assert next.authored == @empty_source
    assert next.package == @empty_source
  end

  test "paging authored leaves package state byte-for-byte equal" do
    previous = selected_state()
    package = previous.package

    assert {:ok, requested, {:after, "authored-after"}, 3} =
             DashboardAudience.start_request(previous, :authored, :next, "request-a")

    assert {:error, :stale} = DashboardAudience.resolve_row(requested, :authored, "authored-row")

    assert requested.package == package

    assert {:replace, next, [_row]} =
             DashboardAudience.accept_result(
               requested,
               :authored,
               3,
               "request-a",
               {:ok, page([target("authored-b")], "authored-before-b", "authored-after-b")}
             )

    assert next.package == package
    assert next.authored.before == "authored-before-b"
    assert next.authored.after == "authored-after-b"
  end

  test "a failed next page preserves the previous window and records only that source error" do
    previous = selected_state()

    assert {:ok, requested, {:after, "authored-after"}, 3} =
             DashboardAudience.start_request(previous, :authored, :next, "request-a")

    assert {:preserve, next} =
             DashboardAudience.accept_result(
               requested,
               :authored,
               3,
               "request-a",
               {:error, :synthetic_page_failure}
             )

    assert next.authored.before == previous.authored.before
    assert next.authored.after == previous.authored.after
    assert next.authored.expected == previous.authored.expected
    assert next.authored.error == :load_failed
    assert {:error, :stale} = DashboardAudience.resolve_row(next, :authored, "authored-row")

    assert {:ok, %{source: :package}} =
             DashboardAudience.resolve_row(next, :package, "package-row")

    refute next.authored.loading?
    assert next.package == previous.package
  end

  test "late request references and old epochs are ignored" do
    previous = selected_state()

    assert {:ok, requested, :first, 3} =
             DashboardAudience.start_request(previous, :package, :first, "current-request")

    assert {:ignore, ^requested} =
             DashboardAudience.accept_result(
               requested,
               :package,
               3,
               "late-request",
               {:ok, page([target("package-b")], nil, nil)}
             )

    assert {:ignore, ^requested} =
             DashboardAudience.accept_result(
               requested,
               :package,
               2,
               "current-request",
               {:ok, page([target("package-b")], nil, nil)}
             )
  end

  test "successful replacement caps the expected window and sanitized rows at 50" do
    previous = selected_state()

    assert {:ok, requested, :first, 3} =
             DashboardAudience.start_request(previous, :authored, :first, "request-a")

    targets = Enum.map(1..60, &target("authored-#{&1}"))

    assert {:replace, next, rows} =
             DashboardAudience.accept_result(
               requested,
               :authored,
               3,
               "request-a",
               {:ok, page(targets, nil, "authored-after")}
             )

    assert length(rows) == 50
    assert map_size(next.authored.expected) <= 50

    assert Enum.all?(rows, fn row ->
             row |> Map.keys() |> Enum.sort() == [:access, :id, :name, :public?, :row_token]
           end)
  end

  test "paged-out, forged, cross-group, and old-epoch tokens are stale" do
    state_for_group_a = selected_state()
    token_from_group_a = "authored-row"

    assert {:ok, _entry} = DashboardAudience.resolve_row(state_for_group_a, token_from_group_a)

    state_for_group_b =
      DashboardAudience.select_group(
        state_for_group_a,
        "group-token-b",
        "group-b",
        "Synthetic group B"
      )

    assert {:error, :stale} =
             DashboardAudience.resolve_row(state_for_group_b, token_from_group_a)

    assert {:error, :stale} = DashboardAudience.resolve_row(state_for_group_a, "forged-row")

    cross_group =
      put_in(
        state_for_group_a.authored.expected[token_from_group_a].group_id,
        "different-group"
      )

    assert {:error, :stale} = DashboardAudience.resolve_row(cross_group, token_from_group_a)

    old_epoch =
      put_in(state_for_group_a.authored.expected[token_from_group_a].epoch, 2)

    assert {:error, :stale} = DashboardAudience.resolve_row(old_epoch, token_from_group_a)

    assert {:ok, requested, :first, 3} =
             DashboardAudience.start_request(state_for_group_a, :authored, :first, "request-a")

    assert {:replace, paged, [_row]} =
             DashboardAudience.accept_result(
               requested,
               :authored,
               3,
               "request-a",
               {:ok, page([target("authored-new")], nil, nil)}
             )

    assert {:error, :stale} = DashboardAudience.resolve_row(paged, token_from_group_a)
  end

  test "source-specific resolution rejects a token from the other source" do
    state = selected_state()

    assert {:error, :stale} =
             DashboardAudience.resolve_row(state, :authored, "package-row")

    assert {:ok, %{source: :package}} =
             DashboardAudience.resolve_row(state, :package, "package-row")
  end

  test "repeated forward and backward replacements retain two raw keysets and no history" do
    initial = selected_state()

    assert {:ok, forward_request, {:after, "authored-after"}, 3} =
             DashboardAudience.start_request(initial, :authored, :next, "forward")

    assert {:replace, forward, [_row]} =
             DashboardAudience.accept_result(
               forward_request,
               :authored,
               3,
               "forward",
               {:ok, page([target("authored-next")], "next-before", "next-after")}
             )

    assert {:ok, backward_request, {:before, "next-before"}, 3} =
             DashboardAudience.start_request(forward, :authored, :previous, "backward")

    assert {:replace, backward, [_row]} =
             DashboardAudience.accept_result(
               backward_request,
               :authored,
               3,
               "backward",
               {:ok, page([target("authored-previous")], "previous-before", "previous-after")}
             )

    assert %{before: "previous-before", after: "previous-after"} = backward.authored
    refute Map.has_key?(backward.authored, :history)

    assert backward.authored
           |> Map.take([:before, :after])
           |> map_size() == 2
  end

  test "audience controls render public and edit access as read-only source-accurate states" do
    audience = selected_state()

    html =
      render_component(&Components.dashboard_audience/1,
        audience: audience,
        group_token: "group-token-a",
        group_name: "Synthetic operations group",
        authored_rows: [
          {"authored-public-dom",
           %{
             id: "authored-public",
             row_token: "authored-public",
             name: "Synthetic public authored",
             public?: true,
             access: nil
           }},
          {"authored-edit-dom",
           %{
             id: "authored-edit",
             row_token: "authored-edit",
             name: "Synthetic edit authored",
             public?: false,
             access: :edit
           }}
        ],
        package_rows: [
          {"package-public-dom",
           %{
             id: "package-public",
             row_token: "package-public",
             name: "Synthetic public package",
             public?: true,
             access: nil
           }}
        ]
      )

    page = LazyHTML.from_fragment(html)

    assert LazyHTML.text(page) =~ "Public to users with analytics access"
    assert LazyHTML.text(page) =~ "Public to authenticated users"
    assert LazyHTML.text(page) =~ "Edit access includes view and cannot be removed here"

    assert page
           |> LazyHTML.query("button[data-row-token='authored-public'][disabled]")
           |> present?()

    assert page
           |> LazyHTML.query("button[data-row-token='authored-edit'][disabled]")
           |> present?()
  end

  test "audience controls emit only opaque group and row intent values" do
    raw_target_id = "99999999-9999-4999-8999-999999999999"
    raw_grant_id = "88888888-8888-4888-8888-888888888888"

    audience =
      put_in(
        selected_state().authored.expected["opaque-row-token"],
        %{
          source: :authored,
          group_id: "77777777-7777-4777-8777-777777777777",
          epoch: 3,
          target_id: raw_target_id,
          fingerprint: {:shared, ~U[2026-09-04 10:00:00Z], raw_grant_id, :view, ~U[2026-09-04 10:00:00Z]}
        }
      )

    html =
      render_component(&Components.dashboard_audience/1,
        audience: audience,
        group_token: "opaque-group-token",
        group_name: "Synthetic audience group",
        authored_rows: [
          {"opaque-row-dom",
           %{
             id: "opaque-row-token",
             row_token: "opaque-row-token",
             name: "Synthetic authored dashboard",
             public?: false,
             access: :view
           }}
        ],
        package_rows: []
      )

    page = LazyHTML.from_fragment(html)

    assert page
           |> LazyHTML.query(
             "button[phx-click='revoke_authored_dashboard_group_view'][phx-value-group-token='opaque-group-token'][phx-value-row-token='opaque-row-token']"
           )
           |> present?()

    refute html =~ raw_target_id
    refute html =~ raw_grant_id
    refute html =~ "77777777-7777-4777-8777-777777777777"
    refute html =~ "2026-09-04"
  end

  defp selected_state do
    %{
      group_token: "group-token-a",
      group_id: "group-a",
      group_name: "Synthetic group A",
      epoch: 3,
      authored: %{
        @empty_source
        | before: "authored-before",
          after: "authored-after",
          expected: %{
            "authored-row" => expected(:authored, "group-a", 3, "authored-a")
          }
      },
      package: %{
        @empty_source
        | before: "package-before",
          after: "package-after",
          expected: %{
            "package-row" => expected(:package, "group-a", 3, "package-a")
          }
      }
    }
  end

  defp expected(source, group_id, epoch, target_id) do
    %{
      source: source,
      group_id: group_id,
      epoch: epoch,
      target_id: target_id,
      fingerprint: {:shared, ~U[2026-09-04 10:00:00Z], nil, nil, nil}
    }
  end

  defp page(results, before, after_cursor) do
    %{results: results, before: before, after: after_cursor}
  end

  defp target(id) do
    %{
      id: id,
      title: "Synthetic dashboard #{id}",
      name: "Synthetic package #{id}",
      visibility: :shared,
      updated_at: ~U[2026-09-04 10:00:00Z],
      access_grants: []
    }
  end

  defp present?(selection), do: LazyHTML.to_tree(selection) != []
end
