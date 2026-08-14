defmodule ServiceRadar.Notifications.Validations.ChannelFallbackChain do
  @moduledoc """
  Validates a notification channel's transport-failover target (design D4).

  Failover is exactly ONE hop. A delivery that exhausts `max_attempts`, or that
  cannot reach its agent, moves to `fallback_channel_id` and stops there; it is
  a transport mechanism and is deliberately distinct from escalation, which is a
  human mechanism gated on acknowledgement. Two shapes make that single hop
  meaningless and are rejected here:

    * a channel that fails over to itself, which retries the destination that
      just failed. The `notification_channels_fallback_not_self` check
      constraint enforces this in the database as well; it is mirrored here so
      the operator gets a field-level message instead of a constraint error.
    * a two-channel cycle - A falls back to B while B falls back to A. The
      dispatcher takes one hop and stops, so the cycle never delivers anything
      the first hop did not, while reading to an operator as redundancy.

  Only the immediate hop is checked, because only the immediate hop is
  traversed. A longer ring (A -> B -> C -> A) is a configuration smell rather
  than an outage: the dispatcher never walks past the first fallback, so no
  delivery can loop through it.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Actors.SystemActor

  @impl true
  def validate(changeset, _opts, _context) do
    fallback_id = Ash.Changeset.get_attribute(changeset, :fallback_channel_id)
    channel_id = Ash.Changeset.get_attribute(changeset, :id) || Map.get(changeset.data, :id)

    cond do
      is_nil(fallback_id) ->
        :ok

      not is_nil(channel_id) and fallback_id == channel_id ->
        {:error, field: :fallback_channel_id, message: "cannot be the channel itself"}

      true ->
        validate_no_immediate_cycle(changeset.resource, fallback_id, channel_id)
    end
  end

  # The lookup is Elixir-side work that yields a decision, not an attribute, so
  # the check runs here and reports its result directly. That keeps the
  # enclosing update atomic instead of requiring `require_atomic? false`.
  @impl true
  def atomic(changeset, opts, context) do
    case validate(changeset, opts, context) do
      :ok -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp validate_no_immediate_cycle(_resource, _fallback_id, nil), do: :ok

  defp validate_no_immediate_cycle(resource, fallback_id, channel_id) do
    actor = SystemActor.system(:notification_channel_fallback)

    case Ash.get(resource, fallback_id, actor: actor) do
      {:ok, %{fallback_channel_id: ^channel_id}} ->
        {:error,
         field: :fallback_channel_id, message: "would create a failover loop back to this channel"}

      # A missing or unreadable fallback is the foreign key's error to raise,
      # not this validation's; reporting it here would mask the real cause.
      _other ->
        :ok
    end
  end
end
