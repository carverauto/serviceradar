defmodule ServiceRadar.Automation.Ansible.CallbackCommandRecoveryScheduler do
  @moduledoc "Ensures the callback command recovery worker is scheduled while Oban is available."

  use ServiceRadar.ObanEnsureScheduled,
    workers: [ServiceRadar.Automation.Ansible.CallbackCommandRecoveryWorker],
    label: "AWX callback command recovery scheduler",
    tick: :schedule,
    interval_ms: to_timeout(second: 5),
    named_start?: true,
    include_worker?: false
end
