defmodule ServiceRadar.Automation.Ansible.SecureExecutionLifecycleActions do
  @moduledoc false

  @callback mark_running(map() | struct(), map() | struct()) ::
              {:ok, map()} | {:error, term()}

  @callback complete_terminal(
              map() | struct(),
              map() | struct(),
              [{map() | struct(), atom(), map()}],
              atom(),
              map()
            ) :: {:ok, map()} | {:error, term()}

  @callback fail_closed(
              map() | struct(),
              map() | struct(),
              [map() | struct()],
              atom(),
              map()
            ) :: {:ok, map()} | {:error, term()}
end
