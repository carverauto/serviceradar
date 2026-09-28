defmodule ServiceRadarWebNGWeb.DeduplicationLiveTest do
  # Writes devices, identity decisions and de-duplication tasks; serial like the other
  # CNPG-backed device tests.
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Inventory.DeduplicationTask
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DistinctDeviceAssertion
  alias ServiceRadar.Inventory.Identity.DecisionLog
  alias ServiceRadar.Inventory.Identity.Deduplication
  alias ServiceRadarWebNG.AshTestHelpers

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db

  describe "an operator" do
    setup %{conn: conn} do
      operator = AshTestHelpers.operator_user_fixture()
      %{conn: log_in_user(conn, operator), operator: operator}
    end

    test "sees each open task with its devices and the decision that opened it", %{conn: conn} do
      {task, [a, b]} = open_task!()

      {:ok, view, _html} = live(conn, ~p"/devices/deduplication")

      assert has_element?(view, "#dedup-tasks", a.uid)
      assert has_element?(view, "#dedup-tasks", b.uid)
      assert has_element?(view, "#dedup-tasks", "mac_only_conflict")

      view |> element("#dedup-review-#{task.id}") |> render_click()

      assert has_element?(view, "#dedup-task-devices", a.hostname)
      assert has_element?(view, "#dedup-task-devices", b.hostname)
      assert has_element?(view, "#dedup-task-decisions", "policy_block")
      assert has_element?(view, "#dedup-task-decisions", "02:00:5E:00:53:17")
      assert has_element?(view, "#dedup-merge")
    end

    test "marks the devices distinct", %{conn: conn} do
      {task, [a, b]} = open_task!()
      {:ok, view, _html} = live(conn, ~p"/devices/deduplication")
      view |> element("#dedup-review-#{task.id}") |> render_click()

      view
      |> form("#dedup-resolve-form", %{"note" => "two chassis"})
      |> render_submit(%{"op" => "distinct"})

      assert %DeduplicationTask{status: :distinct, resolution_note: "two chassis"} = reload(task)
      assert Deduplication.asserted_distinct?(a.uid, b.uid)
      assert has_element?(view, "#dedup-task-resolution", "Distinct by")
      refute has_element?(view, "#dedup-tasks", a.uid)
    end

    test "merges into the device it chose to keep", %{conn: conn} do
      {task, [a, b]} = open_task!()
      {:ok, view, _html} = live(conn, ~p"/devices/deduplication")
      view |> element("#dedup-review-#{task.id}") |> render_click()

      view
      |> form("#dedup-resolve-form", %{"survivor" => b.uid})
      |> render_submit(%{"op" => "merge"})

      assert %DeduplicationTask{status: :merged, merged_into: survivor} = reload(task)
      assert survivor == b.uid
      assert deleted?(a.uid)
      refute deleted?(b.uid)
    end

    test "a merge with no device chosen changes nothing", %{conn: conn} do
      {task, [a, b]} = open_task!()
      {:ok, view, _html} = live(conn, ~p"/devices/deduplication")
      view |> element("#dedup-review-#{task.id}") |> render_click()

      html = render_submit(view, "resolve", %{"task_id" => task.id, "op" => "merge"})

      assert html =~ "Choose one of the task&#39;s devices to keep."
      assert %DeduplicationTask{status: :open} = reload(task)
      refute deleted?(a.uid) or deleted?(b.uid)
    end

    test "dismisses a task and reopens it", %{conn: conn} do
      {task, _devices} = open_task!()
      {:ok, view, _html} = live(conn, ~p"/devices/deduplication")
      view |> element("#dedup-review-#{task.id}") |> render_click()

      view |> form("#dedup-resolve-form") |> render_submit(%{"op" => "dismiss"})
      assert %DeduplicationTask{status: :dismissed} = reload(task)
      refute has_element?(view, "#dedup-tasks", hd(task.device_uids))

      view |> element("#dedup-reopen") |> render_click()
      assert %DeduplicationTask{status: :open} = reload(task)
    end

    test "drops a task another session resolved", %{conn: conn, operator: operator} do
      {task, [a, _b]} = open_task!()
      {:ok, view, _html} = live(conn, ~p"/devices/deduplication")
      assert has_element?(view, "#dedup-tasks", a.uid)

      {:ok, _dismissed} = Deduplication.dismiss(task, operator)

      refute has_element?(view, "#dedup-tasks", a.uid)
    end
  end

  describe "a viewer" do
    setup %{conn: conn} do
      viewer = AshTestHelpers.viewer_user_fixture()
      %{conn: log_in_user(conn, viewer)}
    end

    test "reads the queue but cannot resolve a task", %{conn: conn} do
      {task, [a, b]} = open_task!()
      {:ok, view, _html} = live(conn, ~p"/devices/deduplication")

      assert has_element?(view, "#dedup-tasks", a.uid)
      view |> element("#dedup-review-#{task.id}") |> render_click()
      refute has_element?(view, "#dedup-merge")
      refute has_element?(view, "#dedup-distinct")

      # The event is refused even when sent without the form.
      for op <- ["merge", "distinct", "dismiss"] do
        html =
          render_submit(view, "resolve", %{"task_id" => task.id, "op" => op, "survivor" => a.uid})

        assert html =~ "You are not allowed to resolve de-duplication tasks."
      end

      assert %DeduplicationTask{status: :open} = reload(task)
      refute Deduplication.asserted_distinct?(a.uid, b.uid)
      assert [] = assertions_for(a.uid)
      refute deleted?(a.uid) or deleted?(b.uid)
    end
  end

  defp open_task! do
    unique = System.unique_integer([:positive])

    devices =
      for n <- 1..2 do
        AshTestHelpers.device_fixture(%{
          uid: "dedup-live-#{unique}-#{n}",
          hostname: "dedup-host-#{unique}-#{n}.example.com"
        })
      end

    uids = Enum.map(devices, & &1.uid)

    :ok =
      DecisionLog.record(:policy_block, "mac_only_conflict", uids,
        source: "deduplication_live_test",
        evidence: %{"randomized_macs" => ["02:00:5E:00:53:17"]}
      )

    [task] =
      DeduplicationTask
      |> Ash.Query.filter(device_uids == ^Enum.sort(uids))
      |> Ash.read!(actor: AshTestHelpers.system_actor())

    {task, devices}
  end

  defp reload(task), do: Ash.get!(DeduplicationTask, task.id, actor: AshTestHelpers.system_actor())

  defp deleted?(uid) do
    {:ok, device} = Device.get_by_uid(uid, true, actor: AshTestHelpers.system_actor())
    not is_nil(device.deleted_at)
  end

  defp assertions_for(uid) do
    DistinctDeviceAssertion
    |> Ash.Query.filter(device_a == ^uid or device_b == ^uid)
    |> Ash.read!(actor: AshTestHelpers.system_actor())
  end
end
