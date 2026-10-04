defmodule ServiceRadar.Identity.HomepageTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Identity.Homepage

  test "an explicit user homepage beats a group homepage" do
    user = %{homepage_kind: :dashboards, homepage_target: nil}
    groups = [group("Ops", :platform, nil, ~U[2026-01-02 00:00:00Z])]

    assert Homepage.resolve(user, groups, fn _choice -> false end) ==
             {:ok, %{kind: :dashboards, target: nil}}
  end

  test "an explicit platform homepage beats a group dashboard" do
    user = %{homepage_kind: :platform, homepage_target: nil}

    groups = [
      group("Ops", :authored, "11111111-1111-4111-8111-111111111111", ~U[2026-01-02 00:00:00Z])
    ]

    assert {:ok, %{kind: :platform, target: nil}} = Homepage.resolve(user, groups)
  end

  test "a user with no homepage uses the newest group, then the group name" do
    older = group("Zulu", :dashboards, nil, ~U[2026-01-01 00:00:00Z])
    newer_b = group("Bravo", :package, "edge-overview", ~U[2026-02-01 00:00:00Z])

    newer_a =
      group("Alpha", :authored, "22222222-2222-4222-8222-222222222222", ~U[2026-02-01 00:00:00Z])

    assert {:ok, %{kind: :authored, target: "22222222-2222-4222-8222-222222222222"}} =
             Homepage.resolve(%{}, [newer_b, older, newer_a])
  end

  test "an unauthorized saved homepage falls through and reports the skip" do
    user = %{homepage_kind: :authored, homepage_target: "33333333-3333-4333-8333-333333333333"}
    groups = [group("Ops", :dashboards, nil, ~U[2026-01-01 00:00:00Z])]

    allowed? = fn
      %{kind: :authored} -> false
      _choice -> true
    end

    assert {:fallback, %{kind: :dashboards, target: nil}, :unavailable} =
             Homepage.resolve(user, groups, allowed?)
  end

  test "a skipped group homepage falls through to the next group and then the platform home" do
    blocked = group("Newest", :package, "noc-wall", ~U[2026-03-01 00:00:00Z])

    open =
      group("Older", :authored, "44444444-4444-4444-8444-444444444444", ~U[2026-01-01 00:00:00Z])

    allowed? = fn
      %{kind: :package} -> false
      %{kind: :authored, target: "44444444-4444-4444-8444-444444444444"} -> false
      _choice -> true
    end

    assert {:fallback, %{kind: :platform, target: nil}, :unavailable} =
             Homepage.resolve(%{}, [blocked, open], allowed?)
  end

  test "no stored homepage is the platform home without a fallback notice" do
    groups = [group("Ops", nil, nil, ~U[2026-01-01 00:00:00Z])]

    assert Homepage.resolve(%{}, groups, fn _choice -> false end) ==
             {:ok, %{kind: :platform, target: nil}}
  end

  test "a free-text url is not a homepage target" do
    refute Homepage.valid_preference?(:authored, "https://evil.example/phish")
    refute Homepage.valid_preference?(:package, "/dashboards/../../admin")
    refute Homepage.valid_preference?(:platform, "edge-overview")
    assert Homepage.valid_preference?(:package, "edge-overview")
    assert Homepage.valid_preference?(nil, nil)
  end

  test "the stored check rejects a target on a platform homepage" do
    sql = Homepage.preference_check_sql()

    assert sql =~ "homepage_kind IS NULL AND homepage_target IS NULL"
    assert sql =~ "homepage_kind IN ('platform', 'dashboards') AND homepage_target IS NULL"
    assert sql =~ "homepage_kind IN ('authored', 'package')"
    refute sql =~ "http"
  end

  defp group(name, kind, target, assigned_at) do
    %{name: name, homepage_kind: kind, homepage_target: target, assigned_at: assigned_at}
  end
end
