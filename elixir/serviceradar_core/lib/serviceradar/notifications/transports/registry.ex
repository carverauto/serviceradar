defmodule ServiceRadar.Notifications.Transports.Registry do
  @moduledoc """
  Resolves a `:native` provider's stored `implementation_module` string to a
  module, from a **compile-time allowlist** (design D2, tasks 1.4.3).

  ## Why an allowlist and not `String.to_atom/1`

  `implementation_module` is a database column. Database columns are edited by
  operators, by seeds, by migrations, and by anything that reaches the row. The
  Iron Laws forbid `String.to_atom/1` on operator-supplied values, and the reason
  is concrete rather than stylistic: `String.to_atom/1` grows the atom table
  without bound (a denial of service against a long-lived BEAM) and, worse,
  turns "whatever string is in this column" into "any module in the release",
  which is remote code execution wearing a configuration hat.

  `String.to_existing_atom/1` is not the fix either. Every module in the release
  is an existing atom the moment it is loaded, so it narrows the target set to
  "every module ServiceRadar ships" - still arbitrary code, just spelled more
  carefully. Only an explicit list of names is a boundary.

  ## Single source of truth

  This module owns the list. `ServiceRadar.Notifications.NotificationProvider`
  takes its `one_of` validation from `allowlisted_module_names/0` rather than
  keeping a second copy, because two copies of an allowlist is a drift bug
  waiting for the first entry that is added to one and not the other - and the
  failure mode of that drift is either a provider that saves but cannot dispatch,
  or a module that dispatch will resolve but the validator would have refused.

  Adding an entry here is an in-tree change plus a release. That is not an
  accident: it is exactly what makes the `:native` tier different from
  `:declarative` (upload a document) and `:wasm_plugin` (publish a signed
  bundle).

  ## Errors, never raises

  `resolve/1` returns a typed error for an unknown or malformed name. Dispatch is
  a background job handling an incident; a raise there produces an Oban failure
  with a stack trace instead of a `NotificationDelivery` row an operator can read.

  ## Purity

  `resolve/1`, `allowed?/1`, and `name_for/1` are pure lookups over a compile-time
  map: no code loading, no process state, no clock. `conforms?/1` and
  `conformance/1` are the deliberate exceptions - they reflect on a loaded module
  and are for tests and boot-time checks, not for the dispatch path.
  """

  alias ServiceRadar.Notifications.Transport

  # The compile-time allowlist. Entries are `{stored_name, module}`; the stored
  # name is what a `:native` NotificationProvider row carries in
  # `implementation_module`.
  #
  # `:stream` is present for the registry's benefit only. The
  # `notification_providers_native_module` CHECK constraint requires
  # `implementation_module` to be NULL on a `:stream` row, so the stream
  # transport is reached through the provider type; the entry exists so a
  # conformance sweep still covers it.
  @allowlist [
    {"ServiceRadar.Notifications.Transports.Slack", ServiceRadar.Notifications.Transports.Slack},
    {"ServiceRadar.Notifications.Transports.Discord",
     ServiceRadar.Notifications.Transports.Discord},
    {"ServiceRadar.Notifications.Transports.GenericWebhook",
     ServiceRadar.Notifications.Transports.GenericWebhook},
    {"ServiceRadar.Notifications.Transports.Email", ServiceRadar.Notifications.Transports.Email},
    {"ServiceRadar.Notifications.Transports.Stream", ServiceRadar.Notifications.Transports.Stream}
  ]

  @by_name Map.new(@allowlist)
  @by_module Map.new(@allowlist, fn {name, module} -> {module, name} end)
  @names Enum.map(@allowlist, &elem(&1, 0))
  @modules Enum.map(@allowlist, &elem(&1, 1))

  # Guarding against the mistake that makes an allowlist useless: two entries
  # that name the same module, or two names that collide, would silently shrink
  # the list at compile time rather than fail.
  if length(@names) != length(Enum.uniq(@names)) do
    raise "duplicate transport name in #{inspect(__MODULE__)} allowlist"
  end

  if length(@modules) != length(Enum.uniq(@modules)) do
    raise "duplicate transport module in #{inspect(__MODULE__)} allowlist"
  end

  @type error ::
          {:unknown_transport_module, String.t()}
          | {:invalid_transport_module, term()}

  @doc """
  The allowlist as `{stored_name, module}` pairs, in declaration order.
  """
  @spec allowlist() :: [{String.t(), module()}]
  def allowlist, do: @allowlist

  @doc """
  The allowlisted `implementation_module` strings, sorted.

  This is the single source of truth consumed by
  `ServiceRadar.Notifications.NotificationProvider`'s `one_of` validation.
  """
  @spec allowlisted_module_names() :: [String.t()]
  def allowlisted_module_names, do: Enum.sort(@names)

  @doc "The allowlisted transport modules, in declaration order."
  @spec modules() :: [module()]
  def modules, do: @modules

  @doc """
  Resolves a stored `implementation_module` string to its module.

  Returns `{:error, {:unknown_transport_module, name}}` for a name that is not
  allowlisted and `{:error, {:invalid_transport_module, value}}` for anything
  that is not a string. It never raises and never calls `String.to_atom/1`.

  A module value is accepted as well, so a caller holding an already-resolved
  module does not have to stringify it first - but it is checked against the same
  allowlist, so an arbitrary module atom is still refused.
  """
  @spec resolve(term()) :: {:ok, module()} | {:error, error()}
  def resolve(name) when is_binary(name) do
    case Map.fetch(@by_name, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_transport_module, name}}
    end
  end

  def resolve(module) when is_atom(module) and not is_nil(module) do
    case Map.fetch(@by_module, module) do
      {:ok, _name} -> {:ok, module}
      :error -> {:error, {:unknown_transport_module, inspect(module)}}
    end
  end

  def resolve(other), do: {:error, {:invalid_transport_module, other}}

  @doc "True when the value names an allowlisted transport."
  @spec allowed?(term()) :: boolean()
  def allowed?(value), do: match?({:ok, _module}, resolve(value))

  @doc """
  The stored name for an allowlisted module.

  Useful when seeding a provider row from a module reference rather than from a
  hand-written string.
  """
  @spec name_for(module()) :: {:ok, String.t()} | {:error, error()}
  def name_for(module) when is_atom(module) and not is_nil(module) do
    case Map.fetch(@by_module, module) do
      {:ok, name} -> {:ok, name}
      :error -> {:error, {:unknown_transport_module, inspect(module)}}
    end
  end

  def name_for(other), do: {:error, {:invalid_transport_module, other}}

  @doc """
  Renders a resolution error as an operator-readable sentence.
  """
  @spec describe_error(error()) :: String.t()
  def describe_error({:unknown_transport_module, name}) do
    "\"#{name}\" is not an allowlisted notification transport; the allowlist is " <>
      Enum.join(allowlisted_module_names(), ", ")
  end

  def describe_error({:invalid_transport_module, value}) do
    "expected an allowlisted notification transport module name, got #{inspect(value)}"
  end

  @doc """
  Reflects on a module and reports how it fails the `Transport` contract.

  Returns `:ok`, or `{:error, problems}` where each problem is one of:

    * `{:not_loaded, module}` - the module is not compiled into the release
    * `{:missing_callback, {name, arity}}` - a required callback is absent
    * `{:legacy_send_callback, {:send, 2}}` - the module still exports the old,
      wrong `send/2` spelling
    * `{:missing_capabilities, [capability]}` - `capabilities/0` omits `:send` or
      `:test`
    * `{:capabilities_not_a_list, term}` - `capabilities/0` returned a non-list

  This is the only function here that loads code, so it belongs in a test or a
  boot check, never on the dispatch path.
  """
  @spec conformance(module()) :: :ok | {:error, [term()]}
  def conformance(module) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      problems =
        missing_callbacks(module) ++ legacy_send(module) ++ capability_problems(module)

      case problems do
        [] -> :ok
        problems -> {:error, problems}
      end
    else
      {:error, [{:not_loaded, module}]}
    end
  end

  @doc "True when `conformance/1` finds nothing wrong."
  @spec conforms?(module()) :: boolean()
  def conforms?(module) when is_atom(module), do: conformance(module) == :ok

  defp missing_callbacks(module) do
    Transport.required_callbacks()
    |> Enum.reject(fn {name, arity} -> function_exported?(module, name, arity) end)
    |> Enum.map(&{:missing_callback, &1})
  end

  defp legacy_send(module) do
    if function_exported?(module, :send, 2) do
      [{:legacy_send_callback, {:send, 2}}]
    else
      []
    end
  end

  defp capability_problems(module) do
    if function_exported?(module, :capabilities, 0) do
      check_capabilities(module.capabilities())
    else
      []
    end
  end

  defp check_capabilities(capabilities) when is_list(capabilities) do
    case Enum.reject(Transport.required_capabilities(), &(&1 in capabilities)) do
      [] -> []
      missing -> [{:missing_capabilities, missing}]
    end
  end

  defp check_capabilities(other), do: [{:capabilities_not_a_list, other}]
end
