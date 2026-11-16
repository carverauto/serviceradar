defmodule ServiceRadar.Camera.ArchiveDestinations do
  @moduledoc """
  Operator archive destination registration and read helpers.

  Operator destinations are registered as immutable `ArchiveBinding` generations
  with `provisioning_ref = "operator:<name>"` (`name` matching
  `[a-z0-9][a-z0-9-]{0,62}`) and the next monotonic `generation` for that
  reference. Changing any field registers a new generation without mutating
  earlier generations or existing block/receipt bindings.
  """

  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Error.Forbidden
  alias Ash.Error.Invalid
  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveDestination
  alias ServiceRadar.Policies.Checks.ActorHasPermission
  alias ServiceRadar.Repo

  require Ash.Query

  @system_actor SystemActor.system(:camera_archive_destinations)
  @operator_prefix "operator:"
  @name_regex ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/
  @lock_namespace :erlang.phash2(:camera_operator_archive_destination)

  @view_permissions [
    "settings.recording.view",
    "settings.recording.manage",
    "settings.recording.operate"
  ]

  @doc """
  Lists immutable `ArchiveBinding` generations after authorizing recording view access.
  """
  @spec list_bindings(keyword()) :: {:ok, [ArchiveBinding.t()]} | {:error, term()}
  def list_bindings(opts \\ []) when is_list(opts) do
    with :ok <- authorize_any(opts, @view_permissions) do
      ArchiveBinding
      |> Ash.Query.sort(inserted_at: :desc, provisioning_ref: :asc, generation: :desc)
      |> Ash.read(actor: @system_actor)
    end
  end

  @doc """
  Registers the next immutable generation for an `operator:<name>` archive destination.

  Accepts atom or string keys: `:name` (or `:provisioning_ref` with `"operator:<name>"`),
  `:endpoint`, `:region`, `:bucket`, and `:namespace` (or `:key_prefix`).
  """
  @spec register_operator(map(), keyword()) :: {:ok, ArchiveBinding.t()} | {:error, term()}
  def register_operator(attrs, opts \\ [])

  def register_operator(attrs, opts) when is_map(attrs) and is_list(opts) do
    with :ok <- authorize_any(opts, ["settings.recording.manage"]),
         {:ok, normalized} <- validate_operator_input(attrs) do
      persist_next_generation(normalized, opts)
    end
  end

  def register_operator(_attrs, opts) when is_list(opts) do
    with :ok <- authorize_any(opts, ["settings.recording.manage"]) do
      {:error,
       Invalid.exception(
         errors: [
           InvalidAttribute.exception(field: :destination, message: "invalid archive destination")
         ]
       )}
    end
  end

  @doc """
  Validates operator destination attributes without performing database I/O.
  """
  @spec validate_operator_input(map()) :: {:ok, map()} | {:error, term()}
  def validate_operator_input(attrs) when is_map(attrs) do
    raw_name = extract_operator_name(attrs)
    endpoint = fetch_trimmed(attrs, :endpoint)
    region = fetch_trimmed(attrs, :region)
    bucket = fetch_trimmed(attrs, :bucket)
    namespace = fetch_namespace(attrs)

    {name_valid?, candidate_ref, name_errors} =
      case raw_name do
        value when is_binary(value) ->
          if Regex.match?(@name_regex, value) do
            {true, @operator_prefix <> value, []}
          else
            {false, "operator:invalid",
             [
               {:name,
                "must be 1..63 lowercase ASCII letters, digits, or hyphens, starting with a letter or digit"}
             ]}
          end

        _ ->
          {false, "operator:invalid",
           [
             {:name,
              "must be 1..63 lowercase ASCII letters, digits, or hyphens, starting with a letter or digit"}
           ]}
      end

    candidate = %{
      "schema_version" => 2,
      "provisioning_ref" => candidate_ref,
      "generation" => 1,
      "purpose" => "recording",
      "provider" => "s3_compatible",
      "endpoint" => endpoint,
      "region" => region,
      "bucket" => bucket,
      "namespace" => namespace,
      "archive_format_version" => 1,
      "required_encryption" => "sse_s3_aes256"
    }

    dest_errors =
      case ArchiveDestination.validate(candidate) do
        {:ok, _} ->
          []

        {:error, reasons} ->
          Enum.reject(reasons, fn {field, _msg} ->
            field == :provisioning_ref and not name_valid?
          end)
      end

    case name_errors ++ dest_errors do
      [] ->
        {:ok,
         %{
           provisioning_ref: candidate_ref,
           endpoint: endpoint,
           region: region,
           bucket: bucket,
           namespace: namespace
         }}

      errors ->
        {:error,
         Invalid.exception(
           errors:
             Enum.map(errors, fn {field, message} ->
               InvalidAttribute.exception(field: field, message: message)
             end)
         )}
    end
  end

  defp persist_next_generation(normalized, opts) do
    register_fn = Keyword.get(opts, :register_fn, &default_register_next/1)
    register_fn.(normalized)
  end

  defp default_register_next(normalized) do
    lock_key = :erlang.phash2(normalized.provisioning_ref)

    Repo.transaction(fn ->
      SQL.query!(Repo, "SELECT pg_advisory_xact_lock($1, $2)", [@lock_namespace, lock_key])

      next_generation =
        case ArchiveBinding
             |> Ash.Query.filter(provisioning_ref == ^normalized.provisioning_ref)
             |> Ash.Query.sort(generation: :desc)
             |> Ash.Query.limit(1)
             |> Ash.Query.select([:generation])
             |> Ash.read_one(actor: @system_actor) do
          {:ok, %ArchiveBinding{generation: current}} ->
            current + 1

          {:ok, nil} ->
            1

          {:error, reason} ->
            Repo.rollback(reason)
        end

      destination = %{
        "schema_version" => 2,
        "provisioning_ref" => normalized.provisioning_ref,
        "generation" => next_generation,
        "purpose" => "recording",
        "provider" => "s3_compatible",
        "endpoint" => normalized.endpoint,
        "region" => normalized.region,
        "bucket" => normalized.bucket,
        "namespace" => normalized.namespace,
        "archive_format_version" => 1,
        "required_encryption" => "sse_s3_aes256"
      }

      case ArchiveBinding.register(destination, actor: @system_actor) do
        {:ok, binding} -> binding
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp extract_operator_name(attrs) do
    case fetch_trimmed(attrs, :name) do
      name when is_binary(name) and name != "" ->
        name

      _ ->
        case fetch_trimmed(attrs, :provisioning_ref) do
          @operator_prefix <> rest -> rest
          other when is_binary(other) and other != "" -> :invalid_ref
          _ -> nil
        end
    end
  end

  defp fetch_namespace(attrs) do
    case fetch_trimmed(attrs, :namespace) do
      value when is_binary(value) -> value
      nil -> fetch_trimmed(attrs, :key_prefix)
    end
  end

  defp fetch_trimmed(map, key) do
    raw =
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> Map.get(map, Atom.to_string(key))
      end

    if is_binary(raw), do: String.trim(raw), else: raw
  end

  defp authorize_any(opts, permissions) do
    actor = resolve_actor(opts)

    cond do
      match?(%{role: :system}, actor) ->
        :ok

      Enum.any?(permissions, &ActorHasPermission.match?(actor, [permission: &1], %{})) ->
        :ok

      true ->
        {:error, Forbidden.exception([])}
    end
  end

  defp resolve_actor(opts) do
    case Keyword.get(opts, :actor) do
      nil ->
        opts
        |> Keyword.get(:scope)
        |> actor_from_scope()

      actor ->
        actor
    end
  end

  defp actor_from_scope(%{user: user, permissions: %MapSet{} = permissions})
       when not is_nil(user) do
    user
    |> Map.take([:id, :email, :role, :role_profile_id])
    |> Map.put(:permissions, permissions)
  end

  defp actor_from_scope(%{actor: actor, permissions: %MapSet{} = permissions})
       when is_map(actor) do
    Map.put(actor, :permissions, permissions)
  end

  defp actor_from_scope(%{user: user}) when not is_nil(user), do: user
  defp actor_from_scope(%{actor: actor}) when not is_nil(actor), do: actor
  defp actor_from_scope(_), do: nil
end
