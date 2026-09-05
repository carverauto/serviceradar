defmodule ServiceRadar.Automation.Ansible.SecureExecutionCurrentAuthority.Source do
  @moduledoc false

  @type authority_snapshot :: %{
          required(:permissions) => MapSet.t(String.t()),
          required(:profile_versions) => [%{id: String.t(), updated_at: DateTime.t()}]
        }

  @callback load_principal(:human | :service_principal, String.t(), String.t() | nil) ::
              {:ok,
               %{
                 required(:principal) => map(),
                 required(:owner) => map(),
                 required(:authority) => authority_snapshot()
               }}
              | {:error, term()}
  @callback load_memberships([String.t()]) :: {:ok, [map()]} | {:error, term()}
  @callback load_current_binding(String.t(), pos_integer()) ::
              {:ok, map()} | {:error, term()}
  @callback active_holds([String.t()]) :: {:ok, [map()]} | {:error, term()}
end
