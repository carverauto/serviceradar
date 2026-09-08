defmodule ServiceRadarWebNGWeb.Api.IdentityController do
  @moduledoc """
  Device identity resolution from an address.

  * `GET  /api/v1/identity/resolve` — one address
  * `POST /api/v1/identity/resolve` — a batch of addresses

  Both call `ServiceRadar.Inventory.Identity.ResolveByAddress`, which already answers
  this question for validation runs: the IP is authoritative, an optional MAC
  corroborates it, and no identity is ever created.

  The point of the route is what it does *not* do. Before it existed, the only way to
  turn an address into a uid was to start a validation run, which requires naming a
  composite check and re-probes the device from every vantage-point agent on it. A
  caller that wanted an identifier had to cause a scan of real hardware to get one --
  and callers are told to use uids elsewhere, notably by the device facts API.

  Resolution is not a probe, so it is a read, and it is gated on its own permission
  rather than on the right to launch probes across a fleet.
  """
  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Identity.ResolveByAddress
  alias ServiceRadarWebNG.RBAC

  @permission "identity.resolve"
  @default_partition "default"
  # The same ceiling validation runs apply to a device list. A caller batching a
  # deployment's worth of switches is already shaped by that limit, and one number is
  # easier to hold than two.
  @max_devices 128

  def resolve(conn, params) do
    with :ok <- require_permission(conn),
         {:ok, target} <- single_target(params) do
      case ResolveByAddress.resolve(Map.put(target, :actor, actor())) do
        {:ok, uid} -> json(conn, %{"data" => resolved(target, uid)})
        {:error, reason} -> render_error(conn, reason)
      end
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def resolve_batch(conn, params) do
    with :ok <- require_permission(conn),
         {:ok, targets} <- batch_targets(params) do
      # One entry per address, and a 200 even when some do not resolve. A caller
      # resolving forty switches where one address is unknown still needs the
      # thirty-nine that worked; failing the request would throw them away.
      json(conn, %{"data" => Enum.map(targets, &resolve_one/1)})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp resolve_one(target) do
    case ResolveByAddress.resolve(Map.put(target, :actor, actor())) do
      {:ok, uid} -> resolved(target, uid)
      {:error, reason} -> Map.merge(echo(target), outcome(reason))
    end
  end

  # Every response echoes the address it is for, so a batch result can be matched to its
  # request without relying on ordering.
  defp echo(target) do
    %{"ip" => target.ip, "partition" => target.partition}
  end

  defp resolved(target, uid), do: Map.put(echo(target), "uid", uid)

  # Ambiguity and a MAC/IP conflict are conditions of an inventory that reconciles
  # identity continuously, not faults. Both name the devices involved, so a caller can
  # report which ones disagree rather than only that something did. That is not a leak:
  # a caller permitted to resolve an address may learn the devices at it.
  #
  # `ambiguous` cannot currently occur: an active device's address is unique
  # (ocsf_devices_unique_active_ip_idx) and an identifier is unique per type, value and
  # partition, so neither resolver branch that returns it can fire. It is handled anyway
  # because the resolver declares it, and a database constraint is not the contract --
  # relaxing that index later should not turn a documented outcome into a 500.
  defp outcome(:not_found), do: %{"error" => "not_found"}
  defp outcome(:invalid_ip), do: %{"error" => "invalid_ip"}
  defp outcome({:ambiguous, uids}), do: %{"error" => "ambiguous", "uids" => uids}

  defp outcome({:mac_ip_conflict, ip_uid, mac_uid}),
    do: %{"error" => "mac_ip_conflict", "ip_uid" => ip_uid, "mac_uid" => mac_uid}

  defp outcome(_), do: %{"error" => "not_found"}

  defp single_target(params) do
    case params["ip"] || params[:ip] do
      ip when is_binary(ip) and ip != "" -> {:ok, normalize(params, default_partition(params))}
      _ -> {:error, :missing_ip}
    end
  end

  defp batch_targets(params) do
    default = default_partition(params)

    case params["devices"] || params[:devices] do
      devices when is_list(devices) -> finalize_batch(Enum.map(devices, &normalize(&1, default)))
      _ -> {:error, :empty_devices}
    end
  end

  # An entry with no address is a malformed request, not an unresolvable one. `ip` is
  # required on each entry in the published schema, so the request is refused rather than
  # the entry being dropped -- dropping it would return fewer results than addresses
  # submitted, which breaks the promise that every entry can be matched to its input, and
  # would hide a caller's bug behind a shorter list.
  defp finalize_batch(targets) do
    cond do
      targets == [] -> {:error, :empty_devices}
      Enum.any?(targets, &(&1.ip in [nil, ""])) -> {:error, :missing_ip}
      length(targets) > @max_devices -> {:error, :too_many_devices}
      true -> {:ok, targets}
    end
  end

  defp normalize(target, default_partition) when is_map(target) do
    %{
      ip: trimmed(target["ip"] || target[:ip]),
      mac: target["mac"] || target[:mac],
      # Each level is coalesced on presence rather than on truthiness. In Elixir only nil
      # and false are falsy, so `target["partition"] || default` keeps a blank string and
      # would then fall through to "default" -- silently ignoring the partition the
      # request asked for.
      partition: present(target["partition"] || target[:partition]) || default_partition
    }
  end

  defp normalize(_target, default_partition), do: %{ip: nil, mac: nil, partition: default_partition}

  defp trimmed(value) when is_binary(value), do: String.trim(value)
  defp trimmed(value), do: value

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp default_partition(params) do
    present(params["partition"] || params[:partition]) || @default_partition
  end

  defp actor, do: SystemActor.system(:identity_resolve_api)

  defp require_permission(conn) do
    if RBAC.can?(conn.assigns[:current_scope], @permission) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp render_error(conn, :forbidden) do
    conn
    |> put_status(:forbidden)
    |> json(%{"error" => "forbidden", "message" => "missing #{@permission}"})
  end

  defp render_error(conn, :missing_ip) do
    conn
    |> put_status(:bad_request)
    |> json(%{"error" => "missing_ip", "message" => "an ip is required for every device"})
  end

  defp render_error(conn, :empty_devices) do
    conn
    |> put_status(:bad_request)
    |> json(%{"error" => "empty_devices", "message" => "at least one device ip is required"})
  end

  defp render_error(conn, :too_many_devices) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      "error" => "too_many_devices",
      "message" => "at most #{@max_devices} devices per request"
    })
  end

  defp render_error(conn, :invalid_ip) do
    conn
    |> put_status(:bad_request)
    |> json(%{"error" => "invalid_ip", "message" => "ip is not a valid address"})
  end

  defp render_error(conn, :not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{"error" => "not_found", "message" => "no device found at that address"})
  end

  # 409, not 404: the address is known, and the inventory disagrees about what is at it.
  # A caller that retries a 404 forever would never learn that.
  defp render_error(conn, {:ambiguous, uids}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      "error" => "ambiguous",
      "message" => "more than one device holds that address",
      "uids" => uids
    })
  end

  defp render_error(conn, {:mac_ip_conflict, ip_uid, mac_uid}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      "error" => "mac_ip_conflict",
      "message" => "the mac belongs to a different device than the ip",
      "ip_uid" => ip_uid,
      "mac_uid" => mac_uid
    })
  end

  defp render_error(conn, _reason) do
    conn
    |> put_status(:not_found)
    |> json(%{"error" => "not_found", "message" => "no device found at that address"})
  end
end
