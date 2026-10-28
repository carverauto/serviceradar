defmodule ServiceRadar.Inventory.Identity.AgentCorroboration do
  @moduledoc """
  Address and hostname corroboration for an agent's device: evidence for review, never
  identity.

  An agent that shares no eligible MAC with another device gets a device of its own
  (`HostInterfaces`), even when that other device sits at one of the agent's addresses
  under the same name. A same-named host at another site, a re-imaged machine, a
  DHCP lease handed on, a NAT'd address and a cloned VM all look exactly like that, and
  only a shared hardware identifier tells them from the same host.

  So the agreement is recorded, not acted on. When another live device in the agent's
  partition holds one of the agent's routable addresses (its primary address, or a
  confirmed alias of it) and its hostname's first label equals the agent's, the pair is
  recorded as a `policy_block` identity decision with reason
  `agent_corroboration_not_identity`. A decision naming two devices opens a
  de-duplication task (`Identity.DecisionLog`), where an operator merges the pair, marks
  it distinct or dismisses it.
  """

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Identity.DecisionLog
  alias ServiceRadar.Inventory.Identity.Resolver

  require Ash.Query
  require Logger

  @reason "agent_corroboration_not_identity"

  @spec capture(map(), term()) :: map()
  def capture(%{hostname: hostname, partition: partition, ips: ips}, actor) do
    label = first_label(hostname)

    candidates =
      with true <- is_binary(label) and ips != [],
           {:ok, found} <- corroborated(label, partition, ips, actor) do
        found
      else
        {:error, reason} ->
          Logger.warning("Agent corroboration capture skipped: #{inspect(reason)}")
          []

        _no_evidence ->
          []
      end

    %{label: label, ips: ips, candidates: candidates}
  end

  @spec record(String.t(), map(), term()) :: :ok
  def record(device_uid, %{label: label, ips: ips, candidates: candidates}, actor) do
    for {other_uid, ip} <- candidates,
        other_uid != device_uid,
        same_label?(other_uid, label, actor) do
      DecisionLog.record(:policy_block, @reason, [device_uid, other_uid],
        subject: ip,
        source: "agent_gateway_sync",
        evidence: %{
          "device_id" => device_uid,
          "corroborated_device_id" => other_uid,
          "address" => ip,
          "hostname_label" => label,
          "agent_addresses" => ips
        }
      )
    end

    :ok
  end

  @doc """
  The first label of a hostname, lowercased: `host01` for both `host01` and
  `host01.site.example.com`. Nil for an empty name or an address literal, which
  name no host.
  """
  @spec first_label(term()) :: String.t() | nil
  def first_label(hostname) when is_binary(hostname) do
    trimmed = String.trim(hostname)

    case :inet.parse_address(String.to_charlist(trimmed)) do
      {:ok, _address} ->
        nil

      {:error, _reason} ->
        case trimmed |> String.downcase() |> String.split(".", parts: 2) do
          [label | _] when label not in ["", "localhost"] -> label
          _ -> nil
        end
    end
  end

  def first_label(_hostname), do: nil

  # {other device uid, the address it was found at}, one per device.
  defp corroborated(label, partition, ips, actor) do
    ips
    |> Enum.reduce_while({:ok, []}, fn ip, {:ok, found} ->
      case address_holders(ip, partition, actor) do
        {:ok, holders} -> {:cont, {:ok, found ++ Enum.map(holders, &{&1, ip})}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, found} ->
        {:ok,
         found
         |> Enum.uniq_by(&elem(&1, 0))
         |> Enum.filter(fn {other_uid, _ip} -> same_label?(other_uid, label, actor) end)}

      error ->
        error
    end
  end

  defp address_holders(ip, partition, actor) do
    with {:ok, primary} <-
           Device
           |> Ash.Query.for_read(:by_ip, %{ip: ip, partition: partition})
           |> Ash.read(actor: actor),
         {:ok, aliased} <- Resolver.lookup_alias_device_ids(ip, partition, actor) do
      {:ok, Enum.uniq(Enum.map(primary, & &1.uid) ++ aliased)}
    end
  end

  defp same_label?(uid, label, actor) do
    case Device.get_by_uid(uid, false, actor: actor) do
      {:ok, %Device{hostname: hostname}} -> first_label(hostname) == label
      _ -> false
    end
  end
end
