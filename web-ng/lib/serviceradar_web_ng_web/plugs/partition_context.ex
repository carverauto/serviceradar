defmodule ServiceRadarWebNGWeb.Plugs.PartitionContext do
  @moduledoc """
  Plug for setting partition context in connections.

  Partitions enable monitoring of overlapping IP address spaces by providing
  logical separation. This plug extracts the partition context from request
  headers or session and adds it to the actor for policy evaluation.

  ## Header

  Use `X-Partition-Id` header to specify the partition:

      curl -H "X-Partition-Id: production-dc1" ...

  ## Session

  The partition can also be stored in the session for UI navigation:

      put_session(conn, :current_partition_id, partition_id)

  ## Actor Integration

  When a partition is specified, it's added to the Ash actor:

      %{
        id: user.id,
        tenant_id: user.tenant_id,
        role: :admin,
        partition_id: "uuid-here"  # Added by this plug
      }

  ## Policy Usage

  Resources can use partition context in policies:

      policy action_type(:read) do
        # Only show data from the specified partition (if set)
        authorize_if expr(
          is_nil(^actor(:partition_id)) or
          partition_id == ^actor(:partition_id)
        )
      end
  """

  import Plug.Conn

  @behaviour Plug

  @partition_header "x-partition-id"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    partition_id = get_partition_id(conn)

    conn
    |> assign(:current_partition_id, partition_id)
    |> update_actor_with_partition(partition_id)
  end

  @doc """
  Extract partition ID from header or session.

  Priority:
  1. X-Partition-Id header (for API requests)
  2. Session :current_partition_id (for UI navigation)
  """
  def get_partition_id(conn) do
    case get_req_header(conn, @partition_header) do
      [partition_id | _] when byte_size(partition_id) > 0 ->
        validate_uuid(partition_id)

      _ ->
        case conn.assigns[:current_partition_id] || get_session(conn, :current_partition_id) do
          nil -> nil
          partition_id -> validate_uuid(partition_id)
        end
    end
  end

  defp validate_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp validate_uuid(_), do: nil

  defp update_actor_with_partition(conn, nil), do: conn

  defp update_actor_with_partition(conn, partition_id) do
    case conn.assigns[:ash_actor] do
      nil ->
        conn

      actor when is_map(actor) ->
        updated_actor = Map.put(actor, :partition_id, partition_id)
        assign(conn, :ash_actor, updated_actor)
    end
  end

  @doc """
  Set the partition context for a connection.

  This is useful for LiveViews that need to switch partitions:

      conn = PartitionContext.set_partition(conn, partition_id)
  """
  def set_partition(conn, partition_id) do
    conn
    |> put_session(:current_partition_id, partition_id)
    |> assign(:current_partition_id, partition_id)
    |> update_actor_with_partition(partition_id)
  end

  @doc """
  Clear the partition context.
  """
  def clear_partition(conn) do
    conn
    |> delete_session(:current_partition_id)
    |> assign(:current_partition_id, nil)
    |> assign(:ash_actor, Map.delete(conn.assigns[:ash_actor] || %{}, :partition_id))
  end

  @doc """
  Build an actor map with optional partition context.

  This is the enhanced version of TenantContext.build_actor/1 that includes
  partition awareness.
  """
  def build_actor_with_partition(user, partition_id \\ nil) do
    base_actor = %{
      id: user.id,
      tenant_id: user.tenant_id,
      role: user.role,
      email: user.email
    }

    if partition_id do
      Map.put(base_actor, :partition_id, partition_id)
    else
      base_actor
    end
  end
end
