defmodule ServiceRadarWebNGWeb.Auth.SAMLAssertionValidator do
  @moduledoc """
  Validation rules for parsed SAML assertions (see
  `ServiceRadarWebNGWeb.Auth.SAMLResponse` for the parsed shape).

  `validate/3` checks the assertion itself: it must carry an `ID` and an
  `Issuer`, a `Conditions` window with both `NotBefore` and `NotOnOrAfter` that
  contains `now` and is no longer than the configured maximum, an unexpired
  bearer `SubjectConfirmationData` when it states a `NotOnOrAfter`, and the
  expected issuer, audience and recipient.

  `validate_in_response_to/2` checks the binding to the AuthnRequest this
  browser session sent.
  """

  alias Plug.Crypto

  @default_max_validity_seconds 300

  @spec validate(map(), map(), DateTime.t()) :: :ok | {:error, atom()}
  def validate(assertion, config, now \\ DateTime.utc_now())

  def validate(assertion, config, %DateTime{} = now) when is_map(assertion) and is_map(config) do
    with :ok <- validate_identity(assertion),
         :ok <- validate_time_window(assertion, now, config),
         :ok <- validate_subject_confirmation_expiry(assertion, now),
         :ok <- validate_issuer(assertion, config) do
      validate_targets(assertion, config)
    end
  end

  def validate(_, _, _), do: {:error, :invalid_assertion}

  @doc """
  Checks that the assertion answers the AuthnRequest this session sent.

  With the stored request ID, the bearer `SubjectConfirmationData` must carry
  an `InResponseTo` equal to it, and the `Response` element's `InResponseTo`,
  when present, must equal it too. With `:unsolicited` (an IdP-initiated login
  the caller has chosen to allow), the assertion must not claim to answer any
  request: one that does belongs to some other session's flow.
  """
  @spec validate_in_response_to(map(), String.t() | :unsolicited) :: :ok | {:error, atom()}
  def validate_in_response_to(assertion, expected_request_id) when is_map(assertion) do
    in_response_to = normalize(get_in(assertion, [:subject_confirmation, :in_response_to]))
    response_in_response_to = normalize(Map.get(assertion, :response_in_response_to))

    case expected_request_id do
      :unsolicited ->
        if is_nil(in_response_to) and is_nil(response_in_response_to),
          do: :ok,
          else: {:error, :unexpected_in_response_to}

      expected when is_binary(expected) and expected != "" ->
        cond do
          is_nil(in_response_to) -> {:error, :missing_in_response_to}
          not matches?(in_response_to, expected) -> {:error, :in_response_to_mismatch}
          is_nil(response_in_response_to) -> :ok
          matches?(response_in_response_to, expected) -> :ok
          true -> {:error, :in_response_to_mismatch}
        end

      _other ->
        {:error, :missing_authn_request}
    end
  end

  defp matches?(value, expected), do: Crypto.secure_compare(value, expected)

  defp validate_identity(assertion) do
    cond do
      is_nil(normalize(Map.get(assertion, :id))) -> {:error, :missing_assertion_id}
      is_nil(normalize(Map.get(assertion, :issuer))) -> {:error, :missing_issuer}
      true -> :ok
    end
  end

  # The bearer confirmation's own NotOnOrAfter is optional here, but when the
  # IdP states one it bounds the assertion as tightly as Conditions does.
  defp validate_subject_confirmation_expiry(assertion, now) do
    case normalize(get_in(assertion, [:subject_confirmation, :not_on_or_after])) do
      nil ->
        :ok

      value ->
        case parse_dt(value) do
          {:ok, not_on_or_after} ->
            if DateTime.before?(now, not_on_or_after),
              do: :ok,
              else: {:error, :subject_confirmation_expired}

          _ ->
            {:error, :invalid_assertion_time}
        end
    end
  end

  defp validate_time_window(assertion, now, config) do
    not_before = get_in(assertion, [:conditions, :not_before])
    not_on_or_after = get_in(assertion, [:conditions, :not_on_or_after])

    case {parse_dt(not_before), parse_dt(not_on_or_after)} do
      {{:ok, nb}, {:ok, noa}} ->
        max_validity_seconds = max_validity_seconds(config)
        validity_seconds = DateTime.diff(noa, nb, :second)

        cond do
          DateTime.before?(now, nb) ->
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
      expected_audience != nil and audience == nil ->
        {:error, :invalid_audience}

      expected_recipient != nil and recipient == nil ->
        {:error, :invalid_recipient}

      expected_audience != nil and audience != expected_audience ->
        {:error, :invalid_audience}

      expected_recipient != nil and recipient != expected_recipient ->
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
