defmodule ServiceRadar.Automation.Ansible.RunWatchdogTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.RunWatchdog

  defp now, do: ~U[2026-05-10 12:00:00Z]

  describe "stuck?/3" do
    test "returns false for a run that just started" do
      run = %{started_at: ~U[2026-05-10 11:59:30Z], inserted_at: nil, metadata: %{}}
      refute RunWatchdog.stuck?(run, now())
    end

    test "returns true for a run started > fallback (1h) ago with no template timeout" do
      run = %{started_at: ~U[2026-05-10 10:30:00Z], inserted_at: nil, metadata: %{}}
      assert RunWatchdog.stuck?(run, now())
    end

    test "honors job_template_timeout_seconds × 2 when present (string keys)" do
      # template timeout 600s => threshold 1200s
      old_run = %{
        started_at: ~U[2026-05-10 11:30:00Z],
        metadata: %{"job_template_timeout_seconds" => 600}
      }

      assert RunWatchdog.stuck?(old_run, now())

      # within threshold
      young_run = %{
        started_at: ~U[2026-05-10 11:50:00Z],
        metadata: %{"job_template_timeout_seconds" => 600}
      }

      refute RunWatchdog.stuck?(young_run, now())
    end

    test "honors job_template_timeout_seconds × 2 (atom keys)" do
      run = %{
        started_at: ~U[2026-05-10 10:00:00Z],
        metadata: %{job_template_timeout_seconds: 60}
      }

      # 2h ago, threshold = 120s, so stuck
      assert RunWatchdog.stuck?(run, now())
    end

    test "falls back to inserted_at when started_at is nil" do
      run = %{
        started_at: nil,
        inserted_at: ~U[2026-05-10 09:00:00Z],
        metadata: %{}
      }

      assert RunWatchdog.stuck?(run, now())
    end

    test "returns false when both started_at and inserted_at are nil" do
      run = %{started_at: nil, inserted_at: nil, metadata: %{}}
      refute RunWatchdog.stuck?(run, now())
    end

    test "respects fallback_timeout_seconds opt" do
      run = %{started_at: ~U[2026-05-10 11:55:00Z], metadata: %{}}
      # 5 minutes ago; with 600s fallback, not stuck
      refute RunWatchdog.stuck?(run, now(), fallback_timeout_seconds: 600)
      # with 60s fallback, stuck
      assert RunWatchdog.stuck?(run, now(), fallback_timeout_seconds: 60)
    end

    test "ignores zero/negative job_template_timeout values" do
      run = %{
        started_at: ~U[2026-05-10 11:50:00Z],
        metadata: %{"job_template_timeout_seconds" => 0}
      }

      # 10 minutes ago; falls back to 1h fallback => not stuck
      refute RunWatchdog.stuck?(run, now())
    end
  end
end
