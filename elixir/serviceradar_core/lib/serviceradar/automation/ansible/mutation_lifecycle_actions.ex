defmodule ServiceRadar.Automation.Ansible.MutationLifecycleActions do
  @moduledoc false

  @callback get_by_idempotency_key(String.t(), String.t()) ::
              {:ok, map() | struct() | nil} | {:error, term()}

  @callback list_for_target(String.t()) :: {:ok, [map() | struct()]} | {:error, term()}

  @callback record_phase(map()) :: {:ok, map() | struct()} | {:error, term()}

  @callback record_phase_and_hold(map(), map(), term()) ::
              {:ok, map()} | {:error, term()}

  @callback record_unknown_and_hold(map(), map(), term()) ::
              {:ok, map()} | {:error, term()}
end
