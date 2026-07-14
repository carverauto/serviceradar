defmodule ServiceRadar.Automation.Ansible.SecureChildLauncher.Adapter do
  @moduledoc false

  @callback load_current_actor(String.t()) :: {:ok, map()} | {:error, term()}

  @callback fresh_authorization(map()) ::
              {:ok,
               %{
                 required(:permissions) => MapSet.t(String.t()),
                 optional(:profile_id) => String.t() | nil,
                 optional(:profile_updated_at) => DateTime.t() | nil
               }}
              | {:error, term()}

  @callback load_playbook(String.t()) :: {:ok, map()} | {:error, term()}
  @callback load_memberships([String.t()]) :: {:ok, [map()]} | {:error, term()}

  @callback load_binding(String.t(), pos_integer()) ::
              {:ok, map()} | {:error, term()}

  @callback load_controller(String.t()) :: {:ok, map()} | {:error, term()}

  @callback active_hold_device_uids([String.t()]) ::
              {:ok, [String.t()]} | {:error, term()}

  @callback launch(map(), map()) :: {:ok, map()} | {:error, term()}
end
