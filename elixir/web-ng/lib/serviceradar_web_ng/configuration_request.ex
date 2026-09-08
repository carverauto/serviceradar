defmodule ServiceRadarWebNG.ConfigurationRequest do
  @moduledoc """
  HTTP concurrency contract shared by declarative configuration APIs.

  ETags encode the resource's update timestamp. The expected value is applied
  to the Ash mutation's database filter, so another writer cannot win between
  a controller read and its update or destroy.
  """

  import Plug.Conn, only: [get_req_header: 2, put_resp_header: 3]

  alias ServiceRadar.Automation.Ansible.ProvisioningIdempotency

  @doc "Runs an authorized resource mutation once for a scoped UUID Idempotency-Key."
  @spec create(Plug.Conn.t(), map(), (-> term()), (String.t() -> term()), keyword()) :: term()
  def create(conn, params, create, read, opts \\ []) do
    case get_req_header(conn, "idempotency-key") do
      [] ->
        if Keyword.get(opts, :required, true), do: {:error, :idempotency_key_required}, else: create.()

      [key] ->
        case Ecto.UUID.cast(key) do
          {:ok, key} ->
            idempotency().run(
              %{
                initiator_id: conn.assigns.current_scope.user.id,
                oauth_client_id: conn.assigns[:oauth_client_id],
                operation: conn.request_path,
                key: key
              },
              params,
              create,
              read
            )

          :error ->
            {:error, :invalid_idempotency_key}
        end

      _ ->
        {:error, :invalid_idempotency_key}
    end
  end

  defp idempotency do
    Application.get_env(:serviceradar_web_ng, :provisioning_idempotency, ProvisioningIdempotency)
  end

  @spec mutation_opts(Plug.Conn.t(), keyword()) :: {:ok, keyword()} | {:error, atom()}
  def mutation_opts(conn, opts \\ []) do
    case get_req_header(conn, "if-match") do
      [] ->
        if Keyword.get(opts, :required, true),
          do: {:error, :precondition_required},
          else: {:ok, []}

      ["\"" <> encoded] ->
        parse_version(encoded)

      _ ->
        {:error, :invalid_precondition}
    end
  end

  @spec constrain(Ash.Changeset.t(), keyword()) :: Ash.Changeset.t()
  def constrain(changeset, opts) do
    case Keyword.fetch(opts, :expected_updated_at) do
      {:ok, %DateTime{} = timestamp} -> Ash.Changeset.filter(changeset, updated_at: timestamp)
      :error -> changeset
    end
  end

  @doc "Checks a version after the caller has acquired a row lock for a multi-step mutation."
  def assert_current(record, opts) do
    case Keyword.fetch(opts, :expected_updated_at) do
      :error -> :ok
      {:ok, timestamp} -> if record.updated_at == timestamp, do: :ok, else: {:error, :conflict}
    end
  end

  @spec put_etag(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def put_etag(conn, %{updated_at: %DateTime{} = timestamp}) do
    put_resp_header(conn, "etag", "\"#{DateTime.to_iso8601(timestamp)}\"")
  end

  def put_etag(conn, _record), do: conn

  @spec normalize_result(term()) :: term()
  def normalize_result({:error, error} = result) do
    if stale?(error), do: {:error, :conflict}, else: result
  end

  def normalize_result(result), do: result

  defp parse_version(encoded) do
    with true <- String.ends_with?(encoded, "\""),
         timestamp = String.slice(encoded, 0, byte_size(encoded) - 1),
         {:ok, parsed, 0} <- DateTime.from_iso8601(timestamp) do
      {:ok, [expected_updated_at: parsed]}
    else
      _ -> {:error, :invalid_precondition}
    end
  end

  defp stale?(%Ash.Error.Changes.StaleRecord{}), do: true
  defp stale?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &stale?/1)
  defp stale?(_), do: false
end
