defmodule ServiceRadar.Automation.Ansible.ExecutionLifecycleActions do
  @moduledoc false

  @callback bind_accepted_job(map() | struct(), map()) ::
              {:ok, map() | struct()} | {:error, term()}

  @callback mark_scope_verified(map() | struct(), [map()], map()) ::
              {:ok, map() | struct()} | {:error, term()}

  @callback reject_scope(map() | struct(), [map()], map()) ::
              :ok | {:error, term()}
end
