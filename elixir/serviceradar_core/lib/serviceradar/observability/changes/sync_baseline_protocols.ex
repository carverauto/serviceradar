defmodule ServiceRadar.Observability.Changes.SyncBaselineProtocols do
  @moduledoc """
  Keeps an MTR policy's protocol set canonical and its legacy single protocol
  in step.

  `baseline_protocols` is stored deduplicated in a fixed order (icmp, udp,
  tcp) so two policies with the same set compare equal and dispatch in the
  same order. `baseline_protocol` mirrors the first protocol of the set; it is
  what a rolled-back release reads. A caller that still sets only
  `baseline_protocol` gets a one-protocol set.
  """

  use Ash.Resource.Change

  @order [:icmp, :udp, :tcp]

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, :baseline_protocols) do
      {:ok, protocols} when is_list(protocols) ->
        canonical = canonical(protocols)

        changeset
        |> Ash.Changeset.force_change_attribute(:baseline_protocols, canonical)
        |> Ash.Changeset.force_change_attribute(:baseline_protocol, legacy_protocol(canonical))

      _ ->
        sync_from_legacy(changeset)
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  @doc "Orders and deduplicates a protocol set."
  @spec canonical([atom()]) :: [atom()]
  def canonical(protocols) when is_list(protocols) do
    Enum.filter(@order, &(&1 in protocols))
  end

  defp sync_from_legacy(changeset) do
    with {:ok, protocol} <- Ash.Changeset.fetch_change(changeset, :baseline_protocol),
         atom when not is_nil(atom) <- legacy_atom(protocol) do
      changeset
      |> Ash.Changeset.force_change_attribute(:baseline_protocols, [atom])
      |> Ash.Changeset.force_change_attribute(:baseline_protocol, Atom.to_string(atom))
    else
      _ -> changeset
    end
  end

  defp legacy_protocol([first | _]), do: Atom.to_string(first)
  defp legacy_protocol([]), do: "icmp"

  defp legacy_atom(protocol) when is_binary(protocol) do
    case protocol |> String.trim() |> String.downcase() do
      "icmp" -> :icmp
      "udp" -> :udp
      "tcp" -> :tcp
      _ -> nil
    end
  end

  defp legacy_atom(_protocol), do: nil
end
