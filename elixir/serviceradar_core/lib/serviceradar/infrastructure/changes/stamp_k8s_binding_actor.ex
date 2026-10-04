defmodule ServiceRadar.Infrastructure.Changes.StampK8sBindingActor do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.force_change_attribute(changeset, :changed_by, actor_name(context.actor))
  end

  defp actor_name(%{email: email}) when is_binary(email) and email != "", do: email
  defp actor_name(%{id: id}) when not is_nil(id), do: to_string(id)
  defp actor_name(actor) when is_binary(actor) and actor != "", do: actor
  defp actor_name(_actor), do: "system"
end
