defmodule ServiceRadar.Automation.Ansible.ScheduleEvaluatorWorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.ScheduleEvaluatorWorker, as: Worker

  defp now, do: ~U[2026-05-10 12:00:00Z]

  describe "decide_outcome/3" do
    test "disabled schedule → :skip_disabled regardless of last run" do
      assert Worker.decide_outcome(%{enabled: false, allow_concurrent: false}, nil, now()) ==
               :skip_disabled

      assert Worker.decide_outcome(
               %{enabled: false, allow_concurrent: true},
               %{state: :running},
               now()
             ) == :skip_disabled
    end

    test "no previous run → :fire" do
      assert Worker.decide_outcome(%{enabled: true, allow_concurrent: false}, nil, now()) ==
               :fire
    end

    test "previous run terminal → :fire" do
      for state <- [:succeeded, :partial, :failed, :unreachable, :canceled] do
        assert Worker.decide_outcome(
                 %{enabled: true, allow_concurrent: false},
                 %{state: state},
                 now()
               ) == :fire
      end
    end

    test "previous run non-terminal + allow_concurrent=false → :skip_overlap" do
      for state <- [:pending, :launching, :running] do
        assert Worker.decide_outcome(
                 %{enabled: true, allow_concurrent: false},
                 %{state: state},
                 now()
               ) == :skip_overlap
      end
    end

    test "previous run non-terminal + allow_concurrent=true → :fire" do
      assert Worker.decide_outcome(
               %{enabled: true, allow_concurrent: true},
               %{state: :running},
               now()
             ) == :fire
    end
  end

  describe "compute_next_run_at/2" do
    test "valid 5-field cron in UTC returns next firing as a UTC datetime" do
      schedule = %{cron: "0 3 * * *", timezone: "UTC"}

      assert {:ok, %DateTime{} = ts} = Worker.compute_next_run_at(schedule, now())
      assert ts.time_zone == "Etc/UTC"
      # next 03:00 UTC after 12:00 today is tomorrow at 03:00
      assert ts.day == 11
      assert ts.hour == 3
      assert ts.minute == 0
    end

    test "Etc/UTC alias resolves" do
      schedule = %{cron: "0 9 * * 1-5", timezone: "Etc/UTC"}
      assert {:ok, %DateTime{} = ts} = Worker.compute_next_run_at(schedule, now())
      assert ts.time_zone == "Etc/UTC"
    end

    test "non-UTC zone with no tzdata returns :timezone_database_unavailable" do
      # Without `:tzdata` (or another time_zone_database) configured the
      # underlying lookup raises ArgumentError; we wrap that into a typed
      # error so the worker can record :error rather than crashing.
      schedule = %{cron: "0 9 * * 1-5", timezone: "America/New_York"}

      assert {:error, :timezone_database_unavailable} =
               Worker.compute_next_run_at(schedule, now())
    end

    test "shorthand expressions (@hourly etc.) work" do
      schedule = %{cron: "@hourly", timezone: "UTC"}
      assert {:ok, %DateTime{}} = Worker.compute_next_run_at(schedule, now())
    end

    test "invalid cron returns {:error, _}" do
      schedule = %{cron: "not-a-cron", timezone: "UTC"}
      assert {:error, _} = Worker.compute_next_run_at(schedule, now())
    end

    test "missing cron / timezone returns :invalid_schedule" do
      assert {:error, :invalid_schedule} =
               Worker.compute_next_run_at(%{cron: nil, timezone: "UTC"}, now())

      assert {:error, :invalid_schedule} =
               Worker.compute_next_run_at(%{cron: "* * * * *", timezone: nil}, now())
    end
  end

  describe "build_host_limit/1" do
    test "joins ansible_inventory_ref host_name values with commas, deduped" do
      devices = [
        %{ansible_inventory_ref: %{"host_name" => "web01"}, hostname: "web01.example.com"},
        %{ansible_inventory_ref: %{"host_name" => "web02"}, hostname: "web02.example.com"},
        %{ansible_inventory_ref: %{"host_name" => "web01"}, hostname: "dup"}
      ]

      assert Worker.build_host_limit(devices) == "web01,web02"
    end

    test "supports atom-keyed inventory_ref" do
      devices = [%{ansible_inventory_ref: %{host_name: "db01"}, hostname: nil}]
      assert Worker.build_host_limit(devices) == "db01"
    end

    test "falls back to device hostname when inventory_ref missing host_name" do
      devices = [
        %{ansible_inventory_ref: %{}, hostname: "web01.example.com"},
        %{ansible_inventory_ref: nil, hostname: "web02.example.com"}
      ]

      assert Worker.build_host_limit(devices) == "web01.example.com,web02.example.com"
    end

    test "empty list yields empty string" do
      assert Worker.build_host_limit([]) == ""
    end

    test "skips devices with neither inventory_ref host_name nor hostname" do
      devices = [
        %{ansible_inventory_ref: %{}, hostname: nil},
        %{ansible_inventory_ref: %{"host_name" => "web01"}, hostname: nil}
      ]

      assert Worker.build_host_limit(devices) == "web01"
    end
  end
end
