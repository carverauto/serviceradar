defmodule ServiceRadar.Automation.Ansible.LifecycleScheduler do
  @moduledoc """
  Ensures the AWX/AAP lifecycle seed worker is scheduled once Oban is ready.
  """

  use ServiceRadar.ObanEnsureScheduled,
    workers: [ServiceRadar.Automation.Ansible.LifecycleSeedWorker],
    label: "AWX lifecycle scheduler",
    tick: :schedule,
    named_start?: true,
    include_worker?: false
end
