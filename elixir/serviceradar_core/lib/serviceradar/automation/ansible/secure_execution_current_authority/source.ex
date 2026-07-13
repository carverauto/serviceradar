defmodule ServiceRadar.Automation.Ansible.SecureExecutionCurrentAuthority.Source do
  @moduledoc false

  @callback load_principal(:human | :service_principal, String.t(), String.t() | nil) ::
              {:ok, map()} | {:error, term()}
  @callback load_memberships([String.t()]) :: {:ok, [map()]} | {:error, term()}
  @callback load_current_binding(String.t(), pos_integer()) ::
              {:ok, map()} | {:error, term()}
  @callback active_holds([String.t()]) :: {:ok, [map()]} | {:error, term()}
end
