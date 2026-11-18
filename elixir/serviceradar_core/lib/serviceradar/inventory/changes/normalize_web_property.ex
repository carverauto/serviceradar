defmodule ServiceRadar.Inventory.Changes.NormalizeWebProperty do
  @moduledoc """
  Normalizes and validates `WebProperty` origins, RUM site keys, and query keys
  on `:create` and `:update` (with full `atomic/3` support).
  """

  use Ash.Resource.Change

  @rum_site_key_regex ~r/^sr_rum_[A-Za-z0-9_-]{16,}$/

  @doc """
  Normalizes a canonical origin to `scheme://host[:port]`.

  - Lowercases scheme and host
  - Rejects non-http/https schemes, missing hosts, invalid ports, and userinfo
  - Strips path, query, fragment, and default ports (`:80` for http, `:443` for https)
  """
  @spec normalize_canonical_origin(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_canonical_origin(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    cond do
      trimmed == "" ->
        {:error, "cannot be blank"}

      String.match?(trimmed, ~r/\s/) ->
        {:error, "cannot contain whitespace"}

      true ->
        parse_and_normalize_origin(trimmed, allow_wildcard?: false)
    end
  end

  def normalize_canonical_origin(_), do: {:error, "must be an http or https origin"}

  @doc "Generates a unique URL-safe `sr_rum_...` public site key."
  @spec generate_rum_site_key() :: String.t()
  def generate_rum_site_key do
    "sr_rum_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end

  @doc "Returns true when `key` matches `^sr_rum_[A-Za-z0-9_-]{16,}$`."
  @spec valid_rum_site_key?(term()) :: boolean()
  def valid_rum_site_key?(key) when is_binary(key), do: Regex.match?(@rum_site_key_regex, key)
  def valid_rum_site_key?(_), do: false

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> maybe_normalize_canonical_origin()
    |> maybe_ensure_rum_site_key()
    |> maybe_normalize_origin_list(:allowed_origins)
    |> maybe_normalize_origin_list(:trace_propagate_origins)
    |> maybe_normalize_string_list(:allowed_query_keys)
    |> maybe_validate_sample_rate()
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    updates = %{}

    with {:ok, updates} <- atomic_canonical_origin(changeset, updates),
         {:ok, updates} <- atomic_origin_list(changeset, :allowed_origins, updates),
         {:ok, updates} <- atomic_origin_list(changeset, :trace_propagate_origins, updates),
         {:ok, updates} <- atomic_string_list(changeset, :allowed_query_keys, updates),
         :ok <- atomic_sample_rate(changeset) do
      if map_size(updates) == 0 do
        :ok
      else
        {:atomic, updates}
      end
    end
  end

  defp maybe_normalize_canonical_origin(changeset) do
    case Ash.Changeset.fetch_change(changeset, :canonical_origin) do
      {:ok, value} ->
        case normalize_canonical_origin(value) do
          {:ok, normalized} ->
            Ash.Changeset.force_change_attribute(changeset, :canonical_origin, normalized)

          {:error, message} ->
            Ash.Changeset.add_error(changeset, field: :canonical_origin, message: message)
        end

      :error ->
        changeset
    end
  end

  defp maybe_ensure_rum_site_key(changeset) do
    if changeset.action && changeset.action.type == :create do
      case Ash.Changeset.get_attribute(changeset, :rum_site_key) do
        value when is_binary(value) ->
          trimmed = String.trim(value)

          if trimmed == "" do
            Ash.Changeset.force_change_attribute(
              changeset,
              :rum_site_key,
              generate_rum_site_key()
            )
          else
            if valid_rum_site_key?(trimmed) do
              Ash.Changeset.force_change_attribute(changeset, :rum_site_key, trimmed)
            else
              Ash.Changeset.add_error(changeset,
                field: :rum_site_key,
                message: "must match ^sr_rum_[A-Za-z0-9_-]{16,}$"
              )
            end
          end

        nil ->
          Ash.Changeset.force_change_attribute(
            changeset,
            :rum_site_key,
            generate_rum_site_key()
          )
      end
    else
      changeset
    end
  end

  defp maybe_normalize_origin_list(changeset, field) do
    case Ash.Changeset.fetch_change(changeset, field) do
      {:ok, values} ->
        case normalize_origin_list(values) do
          {:ok, normalized} ->
            Ash.Changeset.force_change_attribute(changeset, field, normalized)

          {:error, message} ->
            Ash.Changeset.add_error(changeset, field: field, message: message)
        end

      :error ->
        changeset
    end
  end

  defp maybe_normalize_string_list(changeset, field) do
    case Ash.Changeset.fetch_change(changeset, field) do
      {:ok, values} ->
        case normalize_string_list(values) do
          {:ok, normalized} ->
            Ash.Changeset.force_change_attribute(changeset, field, normalized)

          {:error, message} ->
            Ash.Changeset.add_error(changeset, field: field, message: message)
        end

      :error ->
        changeset
    end
  end

  defp maybe_validate_sample_rate(changeset) do
    case Ash.Changeset.fetch_change(changeset, :rum_sample_rate) do
      {:ok, rate} ->
        case validate_sample_rate(rate) do
          :ok -> changeset
          {:error, error} -> Ash.Changeset.add_error(changeset, error)
        end

      :error ->
        changeset
    end
  end

  defp atomic_canonical_origin(changeset, updates) do
    case pending_value(changeset, :canonical_origin) do
      {:ok, value} when is_binary(value) ->
        case normalize_canonical_origin(value) do
          {:ok, normalized} -> {:ok, Map.put(updates, :canonical_origin, normalized)}
          {:error, message} -> {:error, [field: :canonical_origin, message: message]}
        end

      {:ok, _other} ->
        {:error, [field: :canonical_origin, message: "must be an http or https origin"]}

      :error ->
        {:ok, updates}
    end
  end

  defp atomic_origin_list(changeset, field, updates) do
    case pending_value(changeset, field) do
      {:ok, values} when is_list(values) ->
        case normalize_origin_list(values) do
          {:ok, normalized} -> {:ok, Map.put(updates, field, normalized)}
          {:error, message} -> {:error, [field: field, message: message]}
        end

      {:ok, _other} ->
        {:error, [field: field, message: "must be a list of origins"]}

      :error ->
        {:ok, updates}
    end
  end

  defp atomic_string_list(changeset, field, updates) do
    case pending_value(changeset, field) do
      {:ok, values} when is_list(values) ->
        case normalize_string_list(values) do
          {:ok, normalized} -> {:ok, Map.put(updates, field, normalized)}
          {:error, message} -> {:error, [field: field, message: message]}
        end

      {:ok, _other} ->
        {:error, [field: field, message: "must be a list of strings"]}

      :error ->
        {:ok, updates}
    end
  end

  defp atomic_sample_rate(changeset) do
    case pending_value(changeset, :rum_sample_rate) do
      {:ok, rate} -> validate_sample_rate(rate)
      :error -> :ok
    end
  end

  defp pending_value(changeset, field) do
    with :error <- Keyword.fetch(changeset.atomics, field) do
      Ash.Changeset.fetch_change(changeset, field)
    end
  end

  defp validate_sample_rate(rate) when is_number(rate) and rate >= 0.0 and rate <= 1.0, do: :ok

  defp validate_sample_rate(_) do
    {:error, [field: :rum_sample_rate, message: "must be between 0.0 and 1.0"]}
  end

  defp normalize_origin_list(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case normalize_allowed_origin(entry) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, list |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp normalize_origin_list(_), do: {:error, "must be a list of origins"}

  defp normalize_allowed_origin(entry) when is_binary(entry) do
    trimmed = String.trim(entry)

    cond do
      trimmed == "" ->
        {:ok, nil}

      String.match?(trimmed, ~r/\s/) ->
        {:error, "origins cannot contain whitespace"}

      true ->
        case parse_and_normalize_origin(trimmed, allow_wildcard?: true) do
          {:ok, normalized} -> {:ok, normalized}
          {:error, message} -> {:error, message}
        end
    end
  end

  defp normalize_allowed_origin(_), do: {:error, "each origin must be a string"}

  defp normalize_string_list(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      normalized =
        values
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      {:ok, normalized}
    else
      {:error, "must be a list of strings"}
    end
  end

  defp normalize_string_list(_), do: {:error, "must be a list of strings"}

  defp parse_and_normalize_origin(raw, opts) do
    allow_wildcard? = Keyword.get(opts, :allow_wildcard?, false)

    case :uri_string.parse(raw) do
      {:error, _, _} ->
        {:error, "must be a valid http or https origin"}

      %{} = parsed ->
        validate_parsed_origin(parsed, allow_wildcard?)
    end
  end

  defp validate_parsed_origin(parsed, allow_wildcard?) do
    scheme = parsed |> Map.get(:scheme) |> downcase_string()
    raw_host = Map.get(parsed, :host)
    port = Map.get(parsed, :port)

    cond do
      scheme not in ["http", "https"] ->
        {:error, "scheme must be http or https"}

      Map.has_key?(parsed, :userinfo) ->
        {:error, "cannot include userinfo"}

      not is_binary(raw_host) or String.trim(raw_host) == "" ->
        {:error, "must include a valid host"}

      port == :undefined ->
        {:error, "port must be between 1 and 65535"}

      not is_nil(port) and (not is_integer(port) or port < 1 or port > 65_535) ->
        {:error, "port must be between 1 and 65535"}

      true ->
        host = String.downcase(raw_host)

        with :ok <- validate_origin_host(host, allow_wildcard?) do
          formatted_host =
            if String.contains?(host, ":") and not String.starts_with?(host, "[") do
              "[#{host}]"
            else
              host
            end

          port_suffix =
            case {scheme, port} do
              {"http", 80} -> ""
              {"https", 443} -> ""
              {_, nil} -> ""
              {_, port_num} -> ":#{port_num}"
            end

          {:ok, "#{scheme}://#{formatted_host}#{port_suffix}"}
        end
    end
  end

  defp validate_origin_host(host, allow_wildcard?) do
    if String.contains?(host, "*") do
      cond do
        not allow_wildcard? ->
          {:error, "canonical origin cannot contain wildcards"}

        valid_wildcard_host?(host) ->
          :ok

        true ->
          {:error, "wildcard origins must use scheme://*.domain.tld"}
      end
    else
      :ok
    end
  end

  defp valid_wildcard_host?(host) do
    if String.starts_with?(host, "*.") do
      rest = String.replace_prefix(host, "*.", "")
      labels = String.split(rest, ".")

      not String.contains?(rest, "*") and
        length(labels) >= 2 and
        Enum.all?(labels, &(&1 != ""))
    else
      false
    end
  end

  defp downcase_string(val) when is_binary(val), do: String.downcase(val)
  defp downcase_string(_), do: nil
end
