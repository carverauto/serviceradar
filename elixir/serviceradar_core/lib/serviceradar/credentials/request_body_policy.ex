defmodule ServiceRadar.Credentials.RequestBodyPolicy do
  @moduledoc """
  Typed credential-broker policy for request bodies that cross an untrusted
  plugin boundary.

  A `bound_bytes` policy authorizes one exact, non-secret body produced by the
  control plane. `trusted_rewrite` delegates construction of a secret-bearing
  body to a closed host-side handler. `empty` authorizes no request body.
  """

  use Ash.Type

  @bound_body_source "command.authorized_request_body_b64"
  @callback_rewrite_handler "awx_callback_credential.v1"
  @max_body_bytes 2 * 1024 * 1024
  @max_mutations 16
  @sha256_hex ~r/\A[a-f0-9]{64}\z/
  @media_type ~r/\A[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+\z/

  @type t :: %{optional(String.t()) => String.t() | pos_integer()}

  @impl true
  def storage_type(_constraints), do: :map

  @impl true
  def matches_type?(value, _constraints), do: match?({:ok, _policy}, normalize(value))

  @impl true
  def cast_input(nil, _constraints), do: {:ok, %{}}
  def cast_input("", _constraints), do: {:ok, %{}}
  def cast_input(value, _constraints), do: normalize(value)

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, %{}}
  def cast_stored(value, _constraints), do: normalize(value)

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, %{}}
  def dump_to_native(value, _constraints), do: normalize(value)

  @doc "Build a policy for an unsafe request that must carry no body."
  @spec empty(keyword()) :: t()
  def empty(opts \\ []) do
    %{
      "mode" => "empty",
      "max_mutations" => Keyword.get(opts, :max_mutations, 1)
    }
    |> maybe_put("content_type", Keyword.get(opts, :content_type))
    |> validated!()
  end

  @doc "Build a policy that substitutes exact control-plane-produced bytes."
  @spec bound_bytes(binary(), keyword()) :: t()
  def bound_bytes(body, opts \\ []) when is_binary(body) do
    validated!(%{
      "mode" => "bound_bytes",
      "sha256" => sha256(body),
      "source" => @bound_body_source,
      "content_type" => Keyword.get(opts, :content_type, "application/json"),
      "max_bytes" => Keyword.get(opts, :max_bytes, byte_size(body)),
      "max_mutations" => Keyword.get(opts, :max_mutations, 1)
    })
  end

  @doc "Build a policy for a closed trusted host-side request-body rewriter."
  @spec trusted_rewrite(String.t(), keyword()) :: t()
  def trusted_rewrite(handler, opts \\ []) when is_binary(handler) do
    validated!(%{
      "mode" => "trusted_rewrite",
      "handler" => handler,
      "content_type" => Keyword.get(opts, :content_type, "application/json"),
      "max_bytes" => Keyword.get(opts, :max_bytes, 256 * 1024),
      "max_mutations" => Keyword.get(opts, :max_mutations, 1)
    })
  end

  @doc "Return the only currently supported opaque bound-body source."
  def bound_body_source, do: @bound_body_source

  @doc "Return the callback credential host rewrite handler identifier."
  def callback_rewrite_handler, do: @callback_rewrite_handler

  @doc "Validate a policy without casting it through an Ash action."
  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(value) do
    case normalize(value) do
      {:ok, _policy} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Normalize a policy to its exact string-keyed wire representation."
  @spec normalize(term()) :: {:ok, t()} | {:error, atom()}
  def normalize(value) when is_map(value) and map_size(value) == 0, do: {:ok, %{}}

  def normalize(value) when is_map(value) do
    with {:ok, policy} <- stringify_unique_keys(value),
         :ok <- validate_policy(policy) do
      {:ok, policy}
    end
  end

  def normalize(_value), do: {:error, :request_body_policy_must_be_an_object}

  defp validate_policy(%{"mode" => "empty"} = policy) do
    with :ok <- exact_keys(policy, ~w(mode max_mutations), ~w(content_type)),
         :ok <- valid_max_mutations(policy["max_mutations"]) do
      optional_media_type(policy["content_type"])
    end
  end

  defp validate_policy(%{"mode" => "bound_bytes"} = policy) do
    with :ok <-
           exact_keys(
             policy,
             ~w(mode sha256 source content_type max_bytes max_mutations),
             []
           ),
         true <- Regex.match?(@sha256_hex, policy["sha256"] || ""),
         true <- policy["source"] == @bound_body_source,
         :ok <- valid_media_type(policy["content_type"]),
         :ok <- valid_max_bytes(policy["max_bytes"]),
         :ok <- valid_max_mutations(policy["max_mutations"]) do
      :ok
    else
      false -> {:error, :invalid_bound_request_body_policy}
      {:error, _reason} = error -> error
    end
  end

  defp validate_policy(%{"mode" => "trusted_rewrite"} = policy) do
    with :ok <-
           exact_keys(
             policy,
             ~w(mode handler content_type max_bytes max_mutations),
             []
           ),
         true <- policy["handler"] == @callback_rewrite_handler,
         :ok <- valid_media_type(policy["content_type"]),
         :ok <- valid_max_bytes(policy["max_bytes"]),
         :ok <- valid_max_mutations(policy["max_mutations"]) do
      :ok
    else
      false -> {:error, :unreviewed_request_body_rewrite_handler}
      {:error, _reason} = error -> error
    end
  end

  defp validate_policy(%{"mode" => _mode}), do: {:error, :unsupported_request_body_policy_mode}
  defp validate_policy(_policy), do: {:error, :request_body_policy_mode_required}

  defp stringify_unique_keys(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn
      {key, field_value}, {:ok, acc} when is_atom(key) or is_binary(key) ->
        key = to_string(key)

        if Map.has_key?(acc, key) do
          {:halt, {:error, :duplicate_request_body_policy_field}}
        else
          {:cont, {:ok, Map.put(acc, key, field_value)}}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_request_body_policy_field}}
    end)
  end

  defp exact_keys(policy, required, optional) do
    keys = policy |> Map.keys() |> MapSet.new()
    required = MapSet.new(required)
    allowed = MapSet.union(required, MapSet.new(optional))

    if MapSet.subset?(required, keys) and MapSet.subset?(keys, allowed),
      do: :ok,
      else: {:error, :invalid_request_body_policy_fields}
  end

  defp valid_max_bytes(value) when is_integer(value) and value in 1..@max_body_bytes, do: :ok
  defp valid_max_bytes(_value), do: {:error, :invalid_request_body_policy_max_bytes}

  defp valid_max_mutations(value) when is_integer(value) and value in 1..@max_mutations, do: :ok

  defp valid_max_mutations(_value), do: {:error, :invalid_request_body_policy_max_mutations}

  defp optional_media_type(nil), do: :ok
  defp optional_media_type(value), do: valid_media_type(value)

  defp valid_media_type(value) when is_binary(value) do
    if value == String.downcase(String.trim(value)) and byte_size(value) <= 128 and
         Regex.match?(@media_type, value),
       do: :ok,
       else: {:error, :invalid_request_body_policy_content_type}
  end

  defp valid_media_type(_value), do: {:error, :invalid_request_body_policy_content_type}

  defp validated!(policy) do
    case normalize(policy) do
      {:ok, normalized} -> normalized
      {:error, reason} -> raise ArgumentError, "invalid request body policy: #{inspect(reason)}"
    end
  end

  defp sha256(value), do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
