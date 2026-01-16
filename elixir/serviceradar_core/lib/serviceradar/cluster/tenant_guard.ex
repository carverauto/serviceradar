defmodule ServiceRadar.Cluster.TenantGuard do
  @moduledoc """
  Defense-in-depth validation for inter-process communication.

  In a tenant-unaware architecture where each instance serves only one tenant
  (with PostgreSQL schema isolation), TenantGuard provides additional security
  for inter-node communication in clustered deployments.

  ## How It Works

  1. Each process can store a tenant marker in the process dictionary
  2. The calling process's identity is extracted from:
     - Process dictionary (`:serviceradar_tenant`)
     - Node name (if follows naming convention)
     - Client certificate (for external connections)
  3. GenServer operations can validate caller identity

  ## Usage

  ```elixir
  defmodule MyServer do
    use GenServer
    use ServiceRadar.Cluster.TenantGuard

    def init(opts) do
      # In tenant-unaware mode, use a marker like :instance
      set_process_tenant(:instance)
      {:ok, %{}}
    end

    # Validates caller before execution
    def handle_call({:get_data, id}, from, state) do
      guard_tenant!(:instance, from)
      # ... handle request
    end
  end
  ```

  ## Platform Admin Bypass

  Processes with tenant marker `:platform` can access any process.
  This is used by core services that need cross-instance access.

  ## Integration with Ash

  In tenant-unaware mode, the DB connection's search_path determines
  the tenant schema, so explicit tenant passing is not required:

  ```elixir
  def handle_call({:create_device, attrs}, from, state) do
    guard_tenant!(:instance, from)
    # DB search_path handles tenant isolation
    Ash.create(Device, attrs, actor: SystemActor.system(:my_server))
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
  Sets the process marker for the current process.

  Call this in GenServer.init/1 to establish the process's identity.
  Typically use `:instance` for tenant-serving processes or `:platform` for core services.

  # DB connection's search_path determines the schema
  """
  @spec set_process_tenant(atom()) :: :ok
  def set_process_tenant(marker) do
    Process.put(:serviceradar_tenant, marker)
    :ok
  end

  @doc """
  Gets the process marker for the current process.
  """
  @spec get_process_tenant() :: atom() | nil
  def get_process_tenant do
    Process.get(:serviceradar_tenant)
  end

  @doc """
  Guards that the caller's process marker matches the expected marker.

  Raises `ServiceRadar.Cluster.TenantViolation` if mismatch.

  ## Parameters

    - `expected_marker` - The process marker this process belongs to (e.g., `:instance`, `:platform`)
    - `from` - The `{pid, ref}` tuple from GenServer callbacks

  ## Bypass Conditions

  Access is allowed if:
  - Caller marker matches expected marker
  - Caller marker is `:platform` (core services)
  - Caller marker is `:super_admin`
  - Expected marker is `:platform` (platform-wide process)

  # DB connection's search_path determines the schema
  """
  @spec guard_tenant!(atom(), {pid(), reference()}) :: :ok
  def guard_tenant!(expected_marker, {caller_pid, _ref}) do
    caller_marker = resolve_caller_tenant(caller_pid)

    unless authorized?(caller_marker, expected_marker) do
      Logger.warning(
        "Process marker violation: caller=#{inspect(caller_marker)}, " <>
          "expected=#{inspect(expected_marker)}, caller_pid=#{inspect(caller_pid)}"
      )

      raise ServiceRadar.Cluster.TenantViolation,
        message: "Cross-process access denied",
        expected: expected_marker,
        actual: caller_marker,
        caller_pid: caller_pid
    end

    :ok
  end

  @doc """
  Guards that the current process's marker matches the expected marker.

  Use this when you don't have the `from` tuple (e.g., in handle_cast).
  Falls back to extracting marker from the calling process.
  """
  @spec guard_tenant!(atom()) :: :ok
  def guard_tenant!(expected_marker) do
    caller_pid = self()
    caller_marker = resolve_caller_tenant(caller_pid)

    unless authorized?(caller_marker, expected_marker) do
      Logger.warning(
        "Process marker violation: caller=#{inspect(caller_marker)}, " <>
          "expected=#{inspect(expected_marker)}"
      )

      raise ServiceRadar.Cluster.TenantViolation,
        message: "Cross-process access denied",
        expected: expected_marker,
        actual: caller_marker
    end

    :ok
  end

  @doc """
  Validates process marker access without raising.

  Returns `:ok` or `{:error, :marker_mismatch}`.
  """
  @spec validate_tenant(atom(), pid()) :: :ok | {:error, :marker_mismatch}
  def validate_tenant(expected_marker, caller_pid) do
    caller_marker = resolve_caller_tenant(caller_pid)

    if authorized?(caller_marker, expected_marker) do
      :ok
    else
      {:error, :marker_mismatch}
    end
  end

  @doc """
  Extracts process marker from a PID's process dictionary or node.
  """
  @spec resolve_caller_tenant(pid()) :: atom() | nil
  def resolve_caller_tenant(pid) do
    if node(pid) == node() do
      # Local process - check process dictionary
      get_marker_from_process(pid)
    else
      # Remote process - extract from node name
      get_marker_from_node(node(pid))
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================
  # DB connection's search_path determines the schema

  defp authorized?(caller_marker, expected_marker) do
    cond do
      # Same marker - allowed
      caller_marker == expected_marker ->
        true

      # Platform/admin callers can access anything
      caller_marker in [@platform_tenant, @super_admin_tenant] ->
        true

      # Platform processes are accessible by anyone
      expected_marker == @platform_tenant ->
        true

      # Nil caller with nil expected (legacy/unset) - allowed with warning
      is_nil(caller_marker) and is_nil(expected_marker) ->
        Logger.debug("TenantGuard: both caller and expected marker are nil")
        true

      # All other cases - denied
      true ->
        false
    end
  end

  defp get_marker_from_process(pid) do
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

  defp get_marker_from_node(node_name) do
    # Node name format options:
    # 1. gateway-001@partition-1.instance.serviceradar (marker in hostname)
    # 2. gateway-001@10.0.0.1 (no marker info, use certificate)

    node_str = Atom.to_string(node_name)

    case parse_marker_from_node_name(node_str) do
      {:ok, marker} -> marker
      :error -> nil
    end
  end

  defp parse_marker_from_node_name(node_str) do
    # Try to parse: name@component.partition.marker.serviceradar
    case String.split(node_str, "@") do
      [_name, host] ->
        case String.split(host, ".") do
          [_component, _partition, marker, "serviceradar"] ->
            {:ok, String.to_atom(marker)}

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
