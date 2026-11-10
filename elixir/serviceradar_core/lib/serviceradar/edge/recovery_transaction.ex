defmodule ServiceRadar.Edge.RecoveryTransaction do
  @moduledoc false

  alias Ash.Error.Query.InvalidArgument

  # Preserve the recovery owner's bounded atom refusals across Ash's error
  # conversion, while database errors retain their structured original cause.
  def run(resources, fun) do
    resources
    |> Ash.transact(fn ->
      case fun.() do
        {:error, reason} when is_atom(reason) ->
          {:error,
           InvalidArgument.exception(field: :recovery, value: reason, message: "recovery refused")}

        result ->
          result
      end
    end)
    |> case do
      {:ok, result} ->
        result

      {:error, %InvalidArgument{field: :recovery, value: reason}} ->
        {:error, reason}

      {:error, %Ash.Error.Invalid{errors: [%InvalidArgument{field: :recovery, value: reason}]}} ->
        {:error, reason}

      error ->
        error
    end
  end
end
