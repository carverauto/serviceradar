defmodule ServiceRadarWebNGWeb.Auth.SAMLAssertionValidator do
  @moduledoc """
  Validation rules for parsed SAML assertions.
  """

  @default_max_validity_seconds 300

  @spec validate(map(), map(), DateTime.t()) :: :ok | {:error, atom()}
  def validate(assertion, config, now \\ DateTime.utc_now())

  def validate(assertion, config, %DateTime{} = now) when is_map(assertion) and is_map(config) do
    with :ok <- validate_time_window(assertion, now, config),
         :ok <- validate_issuer(assertion, config) do
      validate_targets(assertion, config)
    end
  end

  def validate(_, _, _), do: {:error, :invalid_assertion}

  defp validate_time_window(assertion, now, config) do
    not_before = get_in(assertion, [:conditions, :not_before])
    not_on_or_after = get_in(assertion, [:conditions, :not_on_or_after])

    case {parse_dt(not_before), parse_dt(not_on_or_after)} do
      {{:ok, nb}, {:ok, noa}} ->
        max_validity_seconds = max_validity_seconds(config)
        validity_seconds = DateTime.diff(noa, nb, :second)

        cond do
          DateTime.compare(now, nb) == :lt ->
            {:error, :assertion_not_yet_valid}

          DateTime.compare(now, noa) != :lt ->
            {:error, :assertion_expired}

          validity_seconds <= 0 ->
            {:error, :invalid_assertion_time}

          validity_seconds > max_validity_seconds ->
            {:error, :assertion_window_too_large}

          true ->
            :ok
        end

      _ ->
        {:error, :invalid_assertion_time}
    end
  end

  defp validate_issuer(assertion, config) do
    actual_issuer = normalize(get_in(assertion, [:issuer]))
    expected_issuer = normalize(Map.get(config, :idp_entity_id))

    cond do
      expected_issuer == nil ->
        :ok

      actual_issuer == expected_issuer ->
        :ok

      true ->
        {:error, :invalid_issuer}
    end
  end

  defp validate_targets(assertion, config) do
    audience = normalize(get_in(assertion, [:conditions, :audience]))
    recipient = normalize(get_in(assertion, [:subject_confirmation, :recipient]))
    expected_audience = normalize(Map.get(config, :sp_entity_id))
    expected_recipient = normalize(Map.get(config, :acs_url))

    cond do
      audience != nil and expected_audience != nil and audience != expected_audience ->
        {:error, :invalid_audience}

      recipient != nil and expected_recipient != nil and recipient != expected_recipient ->
        {:error, :invalid_recipient}

      true ->
        :ok
    end
  end

  defp max_validity_seconds(config) do
    case Map.get(config, :assertion_max_validity_seconds) do
      value when is_integer(value) and value > 0 ->
        value

      _ ->
        Application.get_env(
          :serviceradar_web_ng,
          :saml_assertion_max_validity_seconds,
          @default_max_validity_seconds
        )
    end
  end

  defp parse_dt(value) when is_binary(value) and value != "" do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} = err -> err
    end
  end

  defp parse_dt(_), do: :error

  defp normalize(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize(_), do: nil
end
