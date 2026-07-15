defmodule ServiceRadar.Automation.Ansible.SecureLaunchResolver.Adapter do
  @moduledoc false

  @callback load_playbook(String.t(), map()) :: {:ok, map()} | {:error, term()}

  @callback list_current_memberships(String.t(), map()) ::
              {:ok, [map()]} | {:error, term()}

  @callback load_current_approved_binding(String.t(), pos_integer(), map()) ::
              {:ok, map()} | {:error, term()}
end
