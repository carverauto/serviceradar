defmodule ServiceRadar.Actors.SystemActor do
  @moduledoc """
  Generates system actors for background operations.

  System actors allow background processes (GenServers, Oban workers, seeders)
  to perform Ash operations while maintaining authorization policy enforcement.

  ## Usage

      # For tenant instance code (search_path determines schema)
      actor = SystemActor.system(:state_monitor)
      Gateway |> Ash.read(actor: actor)

  ## Why Not authorize?: false?

  Using `authorize?: false` bypasses ALL authorization policies including
  tenant isolation. This creates security vulnerabilities where background
  operations could inadvertently access cross-tenant data.

  System actors ensure:
  1. Authorization policies are properly evaluated
  2. Operations are auditable with identifiable actors
  3. New security policies apply to all operations

  ## Actor Structure

  System actors are maps with the following fields:
  - `id` - Unique identifier (e.g., "system:state_monitor")
  - `email` - Descriptive email for audit logs (e.g., "state-monitor@system.serviceradar")
  - `role` - `:system`
  """

  @type component :: atom()

  @type system_actor :: %{
          id: String.t(),
          email: String.t(),
          role: :system
        }

  @doc """
  Creates a system actor for tenant-unaware mode.

  In tenant-unaware mode, the tenant is implicit from the database connection's
  `search_path`.

  The actor will have:
  - `role: :system` - Recognized by authorization policies

  ## Parameters

  - `component` - Atom identifying the system component (e.g., `:state_monitor`, `:sweep_compiler`)

  ## Examples

      iex> SystemActor.system(:state_monitor)
      %{
        id: "system:state_monitor",
        email: "state-monitor@system.serviceradar",
        role: :system
      }

  ## When to Use

  Use `system/1` in tenant instance code where the DB connection's
  search_path is set by CNPG credentials (tenant isolation is implicit).
  """
  @spec system(component()) :: %{id: String.t(), email: String.t(), role: :system}
  def system(component) when is_atom(component) do
    %{
      id: "system:#{component}",
      email: "#{component_to_email(component)}@system.serviceradar",
      role: :system
    }
  end

  @doc """
  Checks if the given actor is a system actor.

  ## Examples

      iex> SystemActor.system_actor?(%{role: :system})
      true

      iex> SystemActor.system_actor?(%{role: :admin})
      false

      iex> SystemActor.system_actor?(nil)
      false
  """
  @spec system_actor?(any()) :: boolean()
  def system_actor?(%{role: :system}), do: true
  def system_actor?(_), do: false

  # Converts an atom component name to an email-friendly string
  # :state_monitor -> "state-monitor"
  # :sweep_compiler -> "sweep-compiler"
  defp component_to_email(component) do
    component
    |> Atom.to_string()
    |> String.replace("_", "-")
  end
end
