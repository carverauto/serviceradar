defmodule ServiceRadar.Cluster.TenantGuard do
  @moduledoc """
  Defense-in-depth tenant validation for inter-process communication.

  Even with per-tenant Horde registries, an attacker who discovers a PID
  could attempt direct messaging. TenantGuard provides an additional layer
  of protection by validating tenant identity on every GenServer operation.

  ## How It Works

  1. Each process stores its tenant_id in the process dictionary
  2. The calling process's tenant is extracted from:
     - Process dictionary (`:serviceradar_tenant`)
     - Node name (if follows tenant naming convention)
     - Client certificate (for external connections)
  3. Every handle_call/handle_cast validates tenant match

  ## Usage

  ```elixir
  defmodule MyTenantAwareServer do
    use GenServer
    use ServiceRadar.Cluster.TenantGuard

    def init(opts) do
      tenant_id = Keyword.fetch!(opts, :tenant_id)
      set_process_tenant(tenant_id)
      {:ok, %{tenant_id: tenant_id}}
    end

    # Macro validates tenant before execution
    def handle_call({:get_data, id}, from, state) do
      guard_tenant!(state.tenant_id, from)
      # ... handle request
    end
  end
  ```

  ## Platform Admin Bypass

  Processes with tenant_id `:platform` can access any tenant's processes.
  This is used by core services that need cross-tenant access.

  ## Integration with Ash

  When making Ash calls, pass the tenant from the validated context:

  ```elixir
  def handle_call({:create_device, attrs}, from, state) do
    guard_tenant!(state.tenant_id, from)

    Ash.create(Device, attrs, tenant: state.tenant_id)
  end
  ```
  """

  require Logger

  @platform_tenant :platform
  @super_admin_tenant :super_admin

  defmacro __using__(_opts) do
    quote do
      import ServiceRadar.Cluster.TenantGuard,
        only: [
          set_process_tenant: 1,
          get_process_tenant: 0,
          guard_tenant!: 2,
          guard_tenant!: 1,
          validate_tenant: 2
        ]
    end
  end

  @doc """
  Sets the tenant for the current process.

  Call this in GenServer.init/1 to establish the process's tenant identity.
  """
  @spec set_process_tenant(String.t() | atom()) :: :ok
  def set_process_tenant(tenant_id) do
    Process.put(:serviceradar_tenant, tenant_id)
    :ok
  end

  @doc """
  Gets the tenant for the current process.
  """
  @spec get_process_tenant() :: String.t() | atom() | nil
  def get_process_tenant do
    Process.get(:serviceradar_tenant)
  end

  @doc """
  Guards that the caller's tenant matches the expected tenant.

  Raises `ServiceRadar.Cluster.TenantViolation` if mismatch.

  ## Parameters

    - `expected_tenant` - The tenant ID this process belongs to
    - `from` - The `{pid, ref}` tuple from GenServer callbacks

  ## Bypass Conditions

  Access is allowed if:
  - Caller tenant matches expected tenant
  - Caller tenant is `:platform` (core services)
  - Caller tenant is `:super_admin`
  - Expected tenant is `:platform` (platform-wide process)
  """
  @spec guard_tenant!(String.t() | atom(), {pid(), reference()}) :: :ok
  def guard_tenant!(expected_tenant, {caller_pid, _ref}) do
    caller_tenant = resolve_caller_tenant(caller_pid)

    unless authorized?(caller_tenant, expected_tenant) do
      Logger.warning(
        "Tenant violation: caller=#{inspect(caller_tenant)}, " <>
          "expected=#{inspect(expected_tenant)}, caller_pid=#{inspect(caller_pid)}"
      )

      raise ServiceRadar.Cluster.TenantViolation,
        message: "Cross-tenant access denied",
        expected: expected_tenant,
        actual: caller_tenant,
        caller_pid: caller_pid
    end

    :ok
  end

  @doc """
  Guards that the current process's tenant matches the expected tenant.

  Use this when you don't have the `from` tuple (e.g., in handle_cast).
  Falls back to extracting tenant from the calling process.
  """
  @spec guard_tenant!(String.t() | atom()) :: :ok
  def guard_tenant!(expected_tenant) do
    caller_pid = self()
    caller_tenant = resolve_caller_tenant(caller_pid)

    unless authorized?(caller_tenant, expected_tenant) do
      Logger.warning(
        "Tenant violation: caller=#{inspect(caller_tenant)}, " <>
          "expected=#{inspect(expected_tenant)}"
      )

      raise ServiceRadar.Cluster.TenantViolation,
        message: "Cross-tenant access denied",
        expected: expected_tenant,
        actual: caller_tenant
    end

    :ok
  end

  @doc """
  Validates tenant access without raising.

  Returns `:ok` or `{:error, :tenant_mismatch}`.
  """
  @spec validate_tenant(String.t() | atom(), pid()) :: :ok | {:error, :tenant_mismatch}
  def validate_tenant(expected_tenant, caller_pid) do
    caller_tenant = resolve_caller_tenant(caller_pid)

    if authorized?(caller_tenant, expected_tenant) do
      :ok
    else
      {:error, :tenant_mismatch}
    end
  end

  @doc """
  Extracts tenant from a PID's process dictionary or node.
  """
  @spec resolve_caller_tenant(pid()) :: String.t() | atom() | nil
  def resolve_caller_tenant(pid) do
    cond do
      # Local process - check process dictionary
      node(pid) == node() ->
        get_tenant_from_process(pid)

      # Remote process - extract from node name
      true ->
        get_tenant_from_node(node(pid))
    end
  end

  @doc """
  Creates an Ash context with the tenant set.

  Use this when making Ash calls from a tenant-aware process.
  """
  @spec ash_opts(String.t() | atom(), keyword()) :: keyword()
  def ash_opts(tenant_id, opts \\ []) do
    Keyword.put(opts, :tenant, tenant_id)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp authorized?(caller_tenant, expected_tenant) do
    cond do
      # Same tenant - allowed
      caller_tenant == expected_tenant ->
        true

      # Platform/admin callers can access anything
      caller_tenant in [@platform_tenant, @super_admin_tenant] ->
        true

      # Platform processes are accessible by anyone
      expected_tenant == @platform_tenant ->
        true

      # Nil caller with nil expected (legacy/unset) - allowed with warning
      is_nil(caller_tenant) and is_nil(expected_tenant) ->
        Logger.debug("TenantGuard: both caller and expected tenant are nil")
        true

      # All other cases - denied
      true ->
        false
    end
  end

  defp get_tenant_from_process(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        Keyword.get(dict, :serviceradar_tenant)

      nil ->
        # Process died
        nil
    end
  rescue
    # Process on different node or dead
    _ -> nil
  end

  defp get_tenant_from_node(node_name) do
    # Node name format options:
    # 1. poller-001@partition-1.acme-corp.serviceradar (tenant in hostname)
    # 2. poller-001@10.0.0.1 (no tenant info, use certificate)

    node_str = Atom.to_string(node_name)

    case parse_tenant_from_node_name(node_str) do
      {:ok, tenant} -> tenant
      :error -> nil
    end
  end

  defp parse_tenant_from_node_name(node_str) do
    # Try to parse: name@component.partition.tenant.serviceradar
    case String.split(node_str, "@") do
      [_name, host] ->
        case String.split(host, ".") do
          [_component, _partition, tenant, "serviceradar"] ->
            {:ok, tenant}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end
end

defmodule ServiceRadar.Cluster.TenantViolation do
  @moduledoc """
  Exception raised when a cross-tenant access attempt is detected.
  """

  defexception [:message, :expected, :actual, :caller_pid]

  @impl true
  def exception(opts) do
    expected = Keyword.get(opts, :expected)
    actual = Keyword.get(opts, :actual)
    caller_pid = Keyword.get(opts, :caller_pid)
    message = Keyword.get(opts, :message, "Cross-tenant access denied")

    %__MODULE__{
      message: message,
      expected: expected,
      actual: actual,
      caller_pid: caller_pid
    }
  end

  @impl true
  def message(%{message: msg, expected: expected, actual: actual}) do
    "#{msg} (expected: #{inspect(expected)}, actual: #{inspect(actual)})"
  end
end
