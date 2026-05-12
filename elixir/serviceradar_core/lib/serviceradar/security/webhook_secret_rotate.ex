defmodule ServiceRadar.Security.WebhookSecret.Rotate do
  @moduledoc false

  alias ServiceRadar.Security.WebhookSecret

  @spec run(map()) :: {:ok, WebhookSecret.t()} | {:error, term()}
  def run(%{source_name: source_name, secret: secret_value} = args) do
    grace_seconds = Map.get(args, :grace_seconds, 300)
    grace_until = DateTime.add(DateTime.utc_now(), grace_seconds, :second)

    Ash.transaction([WebhookSecret], fn ->
      _ = maybe_supersede_existing(source_name, grace_until)

      WebhookSecret
      |> Ash.Changeset.for_create(:create, %{source_name: source_name, secret: secret_value})
      |> Ash.create!()
    end)
  end

  defp maybe_supersede_existing(source_name, grace_until) do
    case WebhookSecret
         |> Ash.Query.for_read(:active_by_source, %{source_name: source_name})
         |> Ash.read_one() do
      {:ok, nil} ->
        :ok

      {:ok, existing} ->
        existing
        |> Ash.Changeset.for_update(:supersede, %{grace_until: grace_until})
        |> Ash.update!()

      {:error, reason} ->
        Ash.Error.to_error_class(reason)
        |> raise()
    end
  end
end
