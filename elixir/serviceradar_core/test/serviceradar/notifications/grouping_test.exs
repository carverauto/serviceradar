defmodule ServiceRadar.Notifications.GroupingTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.Grouping

  @due ~U[2026-08-11 14:00:00.000000Z]

  test "holds only the first rung of a new group for group_wait_seconds" do
    route = %{group_wait_seconds: 30, group_interval_seconds: 300}

    assert Grouping.not_before(%{
             route: route,
             due_at: @due,
             step_number: 1,
             first_step_number: 1,
             last_sent_at: nil
           }) == DateTime.add(@due, 30, :second)

    assert Grouping.not_before(%{
             route: route,
             due_at: @due,
             step_number: 2,
             first_step_number: 1,
             last_sent_at: nil
           }) == @due
  end

  test "holds a later update until the group interval elapses" do
    last_sent_at = DateTime.add(@due, -60, :second)

    assert Grouping.not_before(%{
             route: %{group_wait_seconds: 30, group_interval_seconds: 300},
             due_at: @due,
             step_number: 1,
             first_step_number: 1,
             last_sent_at: last_sent_at
           }) == DateTime.add(last_sent_at, 300, :second)
  end

  test "never moves a dispatch earlier than the escalation due instant" do
    assert Grouping.not_before(%{
             route: %{group_interval_seconds: 30},
             due_at: @due,
             step_number: 1,
             first_step_number: 1,
             last_sent_at: DateTime.add(@due, -300, :second)
           }) == @due
  end

  test "merges siblings into the message rendered by built-in templates" do
    first = snapshot("alert-1", "Disk pressure", "node-1 at 91%", "warning")
    second = snapshot("alert-2", "CPU pressure", "node-2 at 99%", "critical")

    grouped = Grouping.merge_snapshots(first, second)

    assert grouped["group_size"] == 2
    assert Enum.map(grouped["grouped_alerts"], & &1["id"]) == ["alert-1", "alert-2"]
    assert grouped["title"] == "Disk pressure (+1 grouped)"
    assert grouped["message"] =~ "node-1 at 91%"
    assert grouped["message"] =~ "node-2 at 99%"
  end

  test "a repeated occurrence replaces its member instead of growing the group" do
    first = snapshot("alert-1", "Disk pressure", "node-1 at 91%", "warning")
    newer = snapshot("alert-1", "Disk pressure", "node-1 at 97%", "critical")

    grouped = Grouping.merge_snapshots(Grouping.merge_snapshots(first, first), newer)

    assert grouped["group_size"] == 1
    assert [member] = grouped["grouped_alerts"]
    assert member["message"] == "node-1 at 97%"
    assert member["severity"] == "critical"
  end

  test "bounds retained members" do
    grouped =
      1..(Grouping.max_members() + 1)
      |> Enum.map(&snapshot("alert-#{&1}", "Alert #{&1}", "detail #{&1}", "warning"))
      |> Enum.reduce(%{}, &Grouping.merge_snapshots(&2, &1))

    assert length(grouped["grouped_alerts"]) == Grouping.max_members()
    assert grouped["group_size"] == Grouping.max_members() + 1
    assert grouped["group_truncated"]
    assert List.first(grouped["grouped_alerts"])["id"] == "alert-1"
    assert List.last(grouped["grouped_alerts"])["id"] == "alert-51"
  end

  test "rebuilds a bounded aggregate from durable member snapshots" do
    snapshots = [
      snapshot("alert-1", "Disk pressure", "node-1 at 91%", "warning"),
      snapshot("alert-2", "CPU pressure", "node-2 at 99%", "critical")
    ]

    grouped = Grouping.aggregate_snapshots(snapshots)

    assert grouped["group_size"] == 2
    assert Enum.map(grouped["grouped_alerts"], & &1["id"]) == ["alert-1", "alert-2"]
    assert Grouping.aggregate_snapshots([]) == %{}
  end

  defp snapshot(id, title, message, severity) do
    %{
      "id" => id,
      "title" => title,
      "message" => message,
      "description" => message,
      "severity" => severity,
      "occurrence_count" => 1,
      "last_seen_at" => "2026-08-11T14:00:00Z"
    }
  end
end
