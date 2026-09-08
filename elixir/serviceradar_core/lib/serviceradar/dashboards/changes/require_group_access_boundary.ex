defmodule ServiceRadar.Dashboards.Changes.RequireGroupAccessBoundary do
  @moduledoc false

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidChanges

  @message "must be called through the dashboard group access boundary"

  @impl true
  def validate(changeset, opts, _context) do
    if boundary_owned?(changeset) or not group_subject?(changeset, opts) do
      :ok
    else
      {:error, @message}
    end
  end

  @impl true
  def atomic(changeset, opts, _context) do
    cond do
      boundary_owned?(changeset) ->
        :ok

      Keyword.get(opts, :group_only?, true) ->
        {:error, @message}

      true ->
        {:atomic, [:subject_type], expr(subject_type == :group),
         expr(error(^InvalidChanges, %{fields: [:subject_type], message: ^@message}))}
    end
  end

  defp boundary_owned?(changeset) do
    Map.get(changeset.context, :dashboard_group_access_boundary_owned) == true
  end

  defp group_subject?(changeset, opts) do
    if Keyword.get(opts, :group_only?, true) do
      true
    else
      Ash.Changeset.get_attribute(changeset, :subject_type) == :group or
        match?(%{subject_type: :group}, changeset.data)
    end
  end
end
