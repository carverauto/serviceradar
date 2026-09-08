defmodule ServiceRadar.Automation.Ansible.LifecycleScheduler do
  @moduledoc """
  Ensures the AWX/AAP lifecycle seed worker is scheduled once Oban is ready.
  """

  use ServiceRadar.ObanEnsureScheduled,
    workers: [ServiceRadar.Automation.Ansible.LifecycleSeedWorker],
    label: "AWX lifecycle scheduler",
    tick: :schedule,
    # Backstop cadence: re-enqueue the seed worker every 5 minutes once the
    # prior run completes (the per-controller lifecycle hooks handle real-time
    # changes; this is the boot/safety-net reconcile).
    interval_ms: to_timeout(minute: 5),
    named_start?: true,
    include_worker?: false
end
