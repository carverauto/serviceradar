defmodule ServiceRadar.Infrastructure.Changes.StampK8sBindingActor do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.force_change_attribute(changeset, :changed_by, actor_name(context.actor))
  end

  def actor_name(%{email: email}) when is_binary(email) and email != "", do: email
  def actor_name(%{id: id}) when not is_nil(id), do: to_string(id)
  def actor_name(actor) when is_binary(actor) and actor != "", do: actor
  def actor_name(_actor), do: "system"
end
