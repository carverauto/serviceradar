defmodule ServiceRadar.Inventory.Validations.WebPropertyBindingKind do
  @moduledoc """
  Validates kind-specific required and forbidden target attributes on `WebPropertyBinding`.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    kind = fetch_attr(changeset, :binding_kind)
    cluster_id = fetch_attr(changeset, :cluster_id)
    namespace = fetch_attr(changeset, :namespace)
    resource_kind = fetch_attr(changeset, :resource_kind)
    resource_name = fetch_attr(changeset, :resource_name)
    device_uid = fetch_attr(changeset, :device_uid)
    otel_service_name = fetch_attr(changeset, :otel_service_name)

    validate_kind(
      kind,
      cluster_id,
      namespace,
      resource_kind,
      resource_name,
      device_uid,
      otel_service_name
    )
  end

  @impl true
  def atomic(changeset, opts, context) do
    validate(changeset, opts, context)
  end

  defp fetch_attr(changeset, field) do
    with :error <- Keyword.fetch(changeset.atomics, field),
         :error <- Ash.Changeset.fetch_change(changeset, field) do
      case changeset.data do
        %{^field => value} -> value
        _ -> nil
      end
    else
      {:ok, value} -> value
    end
  end

  defp validate_kind(
         :k8s_public_endpoint,
         cluster_id,
         namespace,
         resource_kind,
         resource_name,
         device_uid,
         otel_service_name
       ) do
    cond do
      blank?(cluster_id) ->
        {:error, field: :cluster_id, message: "is required for k8s_public_endpoint bindings"}

      is_nil(namespace) ->
        {:error, field: :namespace, message: "is required for k8s_public_endpoint bindings"}

      blank?(resource_kind) ->
        {:error, field: :resource_kind, message: "is required for k8s_public_endpoint bindings"}

      blank?(resource_name) ->
        {:error, field: :resource_name, message: "is required for k8s_public_endpoint bindings"}

      not blank?(device_uid) ->
        {:error, field: :device_uid, message: "must be nil for k8s_public_endpoint bindings"}

      not blank?(otel_service_name) ->
        {:error,
         field: :otel_service_name, message: "must be nil for k8s_public_endpoint bindings"}

      true ->
        :ok
    end
  end

  defp validate_kind(
         :origin_device,
         _cluster_id,
         _namespace,
         _resource_kind,
         _resource_name,
         device_uid,
         otel_service_name
       ) do
    cond do
      blank?(device_uid) ->
        {:error, field: :device_uid, message: "is required for origin_device bindings"}

      not blank?(otel_service_name) ->
        {:error, field: :otel_service_name, message: "must be nil for origin_device bindings"}

      true ->
        :ok
    end
  end

  defp validate_kind(
         :otel_service,
         _cluster_id,
         _namespace,
         _resource_kind,
         _resource_name,
         device_uid,
         otel_service_name
       ) do
    cond do
      blank?(otel_service_name) ->
        {:error, field: :otel_service_name, message: "is required for otel_service bindings"}

      not blank?(device_uid) ->
        {:error, field: :device_uid, message: "must be nil for otel_service bindings"}

      true ->
        :ok
    end
  end

  defp validate_kind(_, _, _, _, _, _, _) do
    {:error, field: :binding_kind, message: "is invalid"}
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
