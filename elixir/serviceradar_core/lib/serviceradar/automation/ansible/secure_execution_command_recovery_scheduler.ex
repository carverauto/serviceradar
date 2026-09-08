defmodule ServiceRadar.Automation.Ansible.SecureExecutionCommandRecoveryScheduler do
  @moduledoc "Ensures the hardened non-callback AWX recovery worker remains scheduled."

  use ServiceRadar.ObanEnsureScheduled,
    workers: [ServiceRadar.Automation.Ansible.SecureExecutionCommandRecoveryWorker],
    label: "AWX secure execution recovery scheduler",
    tick: :schedule,
    interval_ms: to_timeout(second: 5),
    named_start?: true,
    include_worker?: false
end
