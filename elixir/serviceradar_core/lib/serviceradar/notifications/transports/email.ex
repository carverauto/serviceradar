defmodule ServiceRadar.Notifications.Transports.Email do
  @moduledoc """
  The `:native` email transport (design D2, tier `:native`).

  The payload is **already rendered** by `ServiceRadar.Notifications.Renderer` -
  `:html` produces an `html` document, `:plain` and `:markdown` produce a `text`
  body. This module renders nothing. It assembles a `Swoosh.Email` from the
  rendered payload and the channel's addressing configuration, hands it to
  `ServiceRadar.OutboundMail.deliver/1`, and reports one `Transport.Result`.

  ## One mailer, and this is not it

  Delivery goes through `OutboundMail.deliver/1` - the same path the identity
  senders use - so the adapter, the credentials, and the `From:` address are
  resolved once for the whole deployment. A transport that opened its own SMTP
  connection would be a second place for all three to be resolved differently,
  and mail that silently goes nowhere is the hardest failure here to notice.

  ## Why a channel can be rejected for a reason that is not in its configuration

  `Swoosh.Adapters.Test` and `Swoosh.Adapters.Local` both answer `{:ok, email}`.
  A channel pointed at either one records every delivery as `:sent` and pages
  nobody, and it looks exactly like a working channel until an incident proves
  otherwise. Worse, `Swoosh.Adapters.SMTP` needs `gen_smtp`, which swoosh
  declares *optional*: without it a perfectly valid relay configuration deploys
  and then fails at the first send.

  So `validate_config/1` checks the resolved mailer as well as the channel
  config, and `deliver/2` checks it again before building anything. The
  diagnostic names the environment variable or setting to change (see
  `OutboundMail.diagnose/0`). A non-delivering adapter is a **permanent**
  failure: retrying a `Swoosh.Adapters.Test` send five times produces five
  successful-looking sends and still delivers nothing.

  ## Configuration

  Stored on `NotificationChannel.config`, which is NOT a sensitive column.

  | Key | Required | Meaning |
  | --- | --- | --- |
  | `to` | yes | Recipients: a list of addresses, or `{"Name", "addr"}`-shaped maps |
  | `cc` | no | Carbon copies, same shape |
  | `bcc` | no | Blind carbon copies, same shape |
  | `from` | no | Sender; defaults to `OutboundMail.from_tuple/0` |
  | `subject_prefix` | no | Prepended to the rendered subject, e.g. `[ServiceRadar]` |

  There is deliberately **no** `relay`, `port`, `hostname`, `adapter`,
  `username`, `password`, or `api_key` key. Those are deployment configuration,
  not channel configuration, and accepting them from a channel row would let an
  operator - or anything that can write that row - point a notification at an
  arbitrary internal host and port. That is the same SSRF-shaped hole the
  outbound URL policy closes for the HTTP transports; email closes it by not
  having the knob at all, and `validate_config/1` rejects the keys explicitly
  rather than ignoring them, so an operator who tries learns why.

  ## Header injection

  Every address and the subject prefix are rejected if they contain a carriage
  return or a line feed, and the assembled subject has control characters
  collapsed to spaces. A `\\r\\n` inside a header value ends the header and
  starts a new one, which is how `Bcc:` gets appended to somebody else's mail.
  The addresses are validated at save time; the subject is sanitised again at
  dispatch, because it comes from rendered alert content rather than from
  operator-reviewed configuration.

  ## Failure classification

  `Result` dispositions follow the same table as every other transport (D4, C7):

    * API-adapter HTTP answers go through
      `Transport.result_from_http_status/2`, so a 429 or a 503 means here
      exactly what it means in the Slack transport.
    * An SMTP reply code found in the error decides the rest: **4xx is
      retryable** (`421` relay busy, `451` local error, `452` out of storage),
      **5xx is permanent** (`550` no such user, `535` bad credentials).
    * Failing that, gen_smtp's own vocabulary decides:
      `:temporary_failure`, `:network_failure`, `:timeout`, `:closed`,
      `:no_more_hosts`, `:retries_exceeded` are retryable; `:permanent_failure`,
      `:auth_failed`, `:no_credentials`, `:invalid_recipients` are permanent.
    * Anything unrecognised is **retryable**. That is the deliberate direction to
      err in: the attempt budget is bounded and small, and losing a page to an
      error nobody has classified yet is worse than spending three attempts on
      it.

  ## What comes back

  `external_correlation_id` is the provider's message id when there is one
  (`%{id: ...}` from an API adapter). Otherwise it is the `Message-ID` this
  transport stamps on the mail, derived from the delivery id - which is what a
  bounce or a reply will carry in `In-Reply-To`, and therefore what a later
  inbound interaction can resolve back to the delivery.

  ## Secrets

  This transport resolves no credential of its own: the relay's username and
  password belong to the deployment mailer and are resolved by `OutboundMail`
  through `ServiceRadar.Credentials.SecretBroker`. Anything the dispatcher did
  resolve into `Request.secrets` is still passed to the scrubber, and every
  persisted `result_summary` passes through
  `ServiceRadar.Automation.Northbound.ActionRedaction` (policy
  `northbound-action-redaction-v1`). There are no `Logger` calls at all, which
  is the only reliable way to keep a relay password out of a log line.

  ## Test seam

  `opts[:mailer]` replaces `OutboundMail` - a module exporting `deliver/2`, or a
  one-argument function taking the email - so no test opens a socket. The
  two-argument module form exists because the resolved mailer configuration
  travels with the send; see `invoke_mailer/3`. `opts[:mailer_config]` (a
  keyword list) and `opts[:mailer_diagnostic]` (`:ok` or `{:error, {class,
  message}}`) replace the resolved deployment mailer, so the configuration
  checks can be exercised in any environment. `validate_config/2` takes the same
  options; `validate_config/1` is the behaviour callback and resolves the real
  mailer.

  See `openspec/changes/add-notification-platform/design.md` (D2, D4, D9).
  """

  @behaviour ServiceRadar.Notifications.Transport

  alias ServiceRadar.Automation.Northbound.ActionRedaction
  alias ServiceRadar.Notifications.Transport
  alias ServiceRadar.Notifications.Transport.Request
  alias ServiceRadar.Notifications.Transport.Result
  alias ServiceRadar.Notifications.Transports.HTTP
  alias ServiceRadar.OutboundMail

  @recipient_fields ~w(to cc bcc)

  # Deployment configuration an operator might reasonably try to put on a
  # channel. Rejected by name so the error explains where it belongs.
  @forbidden_config_keys ~w(adapter relay port hostname username password api_key ssl tls auth)

  # RFC 5321 caps a path at 256 octets; a longer one is a configuration mistake
  # rather than an address.
  @max_address_bytes 256
  @max_recipients 100
  @max_subject_bytes 998
  @max_error_message_bytes 300

  # gen_smtp's own vocabulary, used when no SMTP reply code is present.
  @retryable_reasons ~w(
    temporary_failure
    network_failure
    timeout
    etimedout
    closed
    econnreset
    econnrefused
    nxdomain
    no_more_hosts
    retries_exceeded
    unavailable
    send_timeout
  )a

  @permanent_reasons ~w(
    permanent_failure
    auth_failed
    no_credentials
    invalid_credentials
    invalid_recipients
    invalid_email
    bad_message
    unsupported_option
  )a

  @impl true
  def capabilities, do: [:send, :test, :rich_payload]

  @impl true
  def validate_config(config), do: validate_config(config, [])

  @doc """
  `validate_config/1` with the mailer injected.

  `opts[:mailer_diagnostic]` supplies the result of `OutboundMail.diagnose/0`
  directly and `opts[:mailer_config]` supplies the keyword list to classify;
  without either, the deployment's resolved mailer is used. This arity is not
  part of the `Transport` behaviour - it exists so the configuration rules can
  be tested without a deployment mailer, and so a caller that has already
  resolved the mailer does not resolve it twice.
  """
  @spec validate_config(map(), keyword()) :: :ok | {:error, [Transport.config_error()]}
  def validate_config(config, opts) when is_map(config) and is_list(opts) do
    config = stringify(config)

    errors =
      recipient_errors(config, "to", true) ++
        recipient_errors(config, "cc", false) ++
        recipient_errors(config, "bcc", false) ++
        from_errors(config) ++
        subject_prefix_errors(config) ++
        forbidden_key_errors(config) ++
        mailer_errors(opts)

    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  def validate_config(_config, _opts) do
    {:error, [config_error(nil, "expected a configuration map")]}
  end

  @impl true
  def deliver(%Request{} = request, opts), do: dispatch(request, opts)
  def deliver(_request, _opts), do: invalid_request()

  @impl true
  def test(%Request{} = request, opts), do: dispatch(%{request | is_test: true}, opts)
  def test(_request, _opts), do: invalid_request()

  # --- dispatch -------------------------------------------------------------

  defp dispatch(request, opts) do
    config = stringify(request.config)

    with {:ok, mailer_config} <- check_mailer(opts),
         :ok <- check_forbidden_keys(config),
         {:ok, recipients} <- resolve_recipients(config),
         {:ok, bodies} <- resolve_bodies(request),
         {:ok, email} <- build_email(request, config, recipients, bodies) do
      send_email(email, request, opts, mailer_config)
    else
      {:error, %Result{} = result} -> result
    end
  rescue
    exception -> exception_result(:error, exception)
  catch
    kind, reason -> exception_result(kind, reason)
  end

  # The mailer is checked before anything is assembled, because a
  # non-delivering adapter makes every other question moot and the operator
  # needs the diagnostic, not a report that the mail was accepted.
  #
  # The resolved configuration is carried forward to the send so the message
  # goes out through exactly what was judged here, and so the settings row and
  # its credentials are resolved once per send instead of twice.
  defp check_mailer(opts) do
    {mailer_config, diagnostic} = resolved_mailer(opts)

    case diagnostic do
      :ok ->
        {:ok, mailer_config}

      # Transient: the settings row or the credential broker was briefly
      # unreachable. Losing a page to that is worse than spending a bounded
      # retry budget on it.
      {:error, {:mail_settings_unavailable = class, message}} ->
        {:error,
         Result.retryable_failure("email_" <> Atom.to_string(class),
           error_message: message,
           result_summary: summary(%{})
         )}

      {:error, {class, message}} ->
        {:error,
         Result.permanent_failure("email_" <> Atom.to_string(class),
           error_message: message,
           result_summary: summary(%{})
         )}
    end
  end

  defp check_forbidden_keys(config) do
    case forbidden_keys(config) do
      [] ->
        :ok

      keys ->
        {:error,
         Result.permanent_failure("email_invalid_config",
           error_message: forbidden_key_message(keys),
           result_summary: summary(%{})
         )}
    end
  end

  defp resolve_recipients(config) do
    Enum.reduce_while(@recipient_fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case normalize_recipients(Map.get(config, field)) do
        {:ok, []} when field == "to" ->
          {:halt, {:error, missing_recipients()}}

        {:ok, recipients} ->
          {:cont, {:ok, Map.put(acc, field, recipients)}}

        {:error, message} ->
          {:halt,
           {:error,
            Result.permanent_failure("email_invalid_config",
              error_message: "#{field} #{message}",
              result_summary: summary(%{})
            )}}
      end
    end)
  end

  defp missing_recipients do
    Result.permanent_failure("email_invalid_config",
      error_message: "to is required and must list at least one recipient address",
      result_summary: summary(%{})
    )
  end

  # --- payload --------------------------------------------------------------

  defp resolve_bodies(%Request{payload_format: :html, payload: payload}) when is_map(payload) do
    payload = stringify(payload)

    case {presence(Map.get(payload, "html")), presence(Map.get(payload, "text"))} do
      {nil, nil} ->
        {:error, unsupported_payload("the rendered html payload carries no body")}

      {html, text} ->
        {:ok, %{html: html || presence(Map.get(payload, "body")), text: text}}
    end
  end

  defp resolve_bodies(%Request{payload_format: format, payload: payload})
       when format in [:plain, :markdown] and is_map(payload) do
    payload = stringify(payload)

    case presence(Map.get(payload, "text")) || presence(Map.get(payload, "body")) do
      nil -> {:error, unsupported_payload("the rendered #{format} payload carries no text")}
      text -> {:ok, %{html: nil, text: text}}
    end
  end

  defp resolve_bodies(%Request{payload_format: format}) do
    {:error,
     unsupported_payload(
       "email accepts :html, :plain, and :markdown payloads, got #{inspect(format)}"
     )}
  end

  defp unsupported_payload(message) do
    Result.permanent_failure("email_unsupported_payload",
      error_message: message,
      result_summary: summary(%{})
    )
  end

  # --- email assembly -------------------------------------------------------

  defp build_email(request, config, recipients, bodies) do
    with {:ok, from} <- resolve_from(config) do
      fields =
        [
          from: from,
          to: Map.fetch!(recipients, "to"),
          subject: subject(request, config)
        ]
        |> put_present(:cc, Map.get(recipients, "cc"))
        |> put_present(:bcc, Map.get(recipients, "bcc"))
        |> put_present(:html_body, bodies.html)
        |> put_present(:text_body, bodies.text)

      email =
        fields
        |> Swoosh.Email.new()
        |> put_message_id(message_id(request, from))

      {:ok, email}
    end
  end

  defp resolve_from(config) do
    case Map.get(config, "from") do
      nil ->
        {:ok, OutboundMail.from_tuple()}

      value ->
        case normalize_address(value) do
          {:ok, address} ->
            {:ok, address}

          {:error, message} ->
            {:error,
             Result.permanent_failure("email_invalid_config",
               error_message: "from #{message}",
               result_summary: summary(%{})
             )}
        end
    end
  end

  # The subject is rendered alert content, so it is sanitised here even though
  # `subject_prefix` was validated at save time: a header value with a line
  # break in it ends the header and starts a new one.
  defp subject(request, config) do
    rendered =
      presence(request.subject) ||
        request.payload |> stringify() |> Map.get("subject") |> presence() ||
        "ServiceRadar notification"

    prefix = presence(Map.get(config, "subject_prefix"))

    [prefix, rendered]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> sanitize_header()
    |> truncate(@max_subject_bytes)
  end

  # A stable, deterministic Message-ID: a bounce or a reply carries it in
  # `In-Reply-To`, so it is the email analogue of a Slack `ts`. It is derived
  # from the delivery id rather than generated, so this stays a pure function of
  # the request - no clock, no randomness.
  defp message_id(%Request{delivery_id: delivery_id}, from) when is_binary(delivery_id) do
    case presence(delivery_id) do
      nil -> nil
      id -> "<" <> sanitize_header(id) <> "@" <> message_id_domain(from) <> ">"
    end
  end

  defp message_id(_request, _from), do: nil

  defp message_id_domain({_name, address}), do: message_id_domain(address)

  defp message_id_domain(address) when is_binary(address) do
    case String.split(address, "@", parts: 2) do
      [_local, domain] -> domain
      _other -> "serviceradar.invalid"
    end
  end

  defp message_id_domain(_address), do: "serviceradar.invalid"

  defp put_message_id(email, nil), do: email
  defp put_message_id(email, message_id), do: Swoosh.Email.header(email, "Message-ID", message_id)

  # --- send -----------------------------------------------------------------

  defp send_email(email, request, opts, mailer_config) do
    case invoke_mailer(email, opts, mailer_config) do
      {:ok, metadata} ->
        Result.delivered(
          external_correlation_id: provider_message_id(metadata) || header(email, "Message-ID"),
          result_summary:
            summary(%{
              "recipients" => length(email.to),
              "message_id" => header(email, "Message-ID"),
              "test" => request.is_test
            })
        )

      {:error, reason} ->
        failure_result(reason, sensitive_values(request))

      other ->
        Result.retryable_failure("email_unexpected_mailer_result",
          error_message: "the mailer returned #{inspect_shape(other)}",
          result_summary: summary(%{})
        )
    end
  end

  # `mailer_config` is the configuration `check_mailer/1` already resolved and
  # judged; handing it to `OutboundMail.deliver/2` is what keeps the message
  # from going out through a configuration that was never diagnosed.
  defp invoke_mailer(email, opts, mailer_config) do
    case Keyword.get(opts, :mailer, OutboundMail) do
      mailer when is_function(mailer, 1) -> mailer.(email)
      mailer when is_atom(mailer) -> mailer.deliver(email, mailer_config)
      other -> {:error, {:invalid_mailer, inspect_shape(other)}}
    end
  end

  # --- failure classification -----------------------------------------------

  # An API adapter answers with the provider's HTTP status, so it goes through
  # the shared classifier rather than a second opinion about what a 429 means.
  defp failure_result({status, body}, sensitive) when is_integer(status) do
    Transport.result_from_http_status(status,
      error_message:
        HTTP.scrub("the mail provider answered HTTP #{status}: #{brief(body)}", sensitive),
      result_summary: summary(%{"http_status" => status})
    )
  end

  defp failure_result(reason, sensitive) do
    message = HTTP.scrub(describe_reason(reason), sensitive)

    case smtp_code(reason) do
      nil -> reason_result(reason, message)
      code -> smtp_code_result(code, message)
    end
  end

  defp smtp_code_result(code, message) when code >= 400 and code < 500 do
    Result.retryable_failure("smtp_#{code}",
      error_message: message,
      result_summary: summary(%{"smtp_code" => code})
    )
  end

  defp smtp_code_result(code, message) do
    Result.permanent_failure("smtp_#{code}",
      error_message: message,
      result_summary: summary(%{"smtp_code" => code})
    )
  end

  defp reason_result(reason, message) do
    atoms = reason_atoms(reason)

    cond do
      Enum.any?(atoms, &(&1 in @permanent_reasons)) ->
        Result.permanent_failure(error_class(atoms, @permanent_reasons),
          error_message: message,
          result_summary: summary(%{})
        )

      Enum.any?(atoms, &(&1 in @retryable_reasons)) ->
        Result.retryable_failure(error_class(atoms, @retryable_reasons),
          error_message: message,
          result_summary: summary(%{})
        )

      # Deliberately retryable; see the moduledoc.
      true ->
        Result.retryable_failure("email_delivery_failed",
          error_message: message,
          result_summary: summary(%{})
        )
    end
  end

  defp error_class(atoms, vocabulary) do
    "email_" <> Atom.to_string(Enum.find(atoms, &(&1 in vocabulary)))
  end

  defp reason_atoms(reason) when is_atom(reason), do: [reason]

  defp reason_atoms(reason) when is_tuple(reason) do
    reason |> Tuple.to_list() |> Enum.flat_map(&reason_atoms/1)
  end

  defp reason_atoms(reason) when is_list(reason), do: Enum.flat_map(reason, &reason_atoms/1)
  defp reason_atoms(_reason), do: []

  # gen_smtp hands back the relay's reply verbatim ("550 5.1.1 <a@b> User
  # unknown"), so the reply code is the most specific thing available and it is
  # what decides retryability when it is present.
  defp smtp_code(reason) do
    reason
    |> reason_binaries()
    |> Enum.find_value(&leading_smtp_code/1)
  end

  defp reason_binaries(reason) when is_binary(reason), do: [reason]

  defp reason_binaries(reason) when is_tuple(reason) do
    reason |> Tuple.to_list() |> Enum.flat_map(&reason_binaries/1)
  end

  defp reason_binaries(reason) when is_list(reason) do
    if List.ascii_printable?(reason) do
      [List.to_string(reason)]
    else
      Enum.flat_map(reason, &reason_binaries/1)
    end
  end

  defp reason_binaries(_reason), do: []

  defp leading_smtp_code(value) do
    case Regex.run(~r/^\s*(\d{3})\b/, value) do
      [_match, code] -> code |> String.to_integer() |> valid_smtp_code()
      _other -> nil
    end
  end

  defp valid_smtp_code(code) when code >= 200 and code <= 599, do: code
  defp valid_smtp_code(_code), do: nil

  defp describe_reason(reason) when is_binary(reason),
    do: truncate(reason, @max_error_message_bytes)

  defp describe_reason(reason) do
    reason
    |> inspect(limit: 8, printable_limit: @max_error_message_bytes)
    |> truncate(@max_error_message_bytes)
  end

  defp brief(body) when is_binary(body), do: truncate(body, @max_error_message_bytes)
  defp brief(body), do: body |> inspect(limit: 5) |> truncate(@max_error_message_bytes)

  # Only the shape of an unexpected value, never its contents: an unrecognised
  # mailer answer can carry the whole email, recipients included.
  defp inspect_shape(%module{}), do: inspect(module)
  defp inspect_shape(value) when is_atom(value), do: inspect(value)
  defp inspect_shape(value) when is_tuple(value), do: "a #{tuple_size(value)}-tuple"
  defp inspect_shape(value) when is_list(value), do: "a list"
  defp inspect_shape(value) when is_map(value), do: "a map"
  defp inspect_shape(value) when is_binary(value), do: "a string"
  defp inspect_shape(_value), do: "an unrecognised value"

  # --- configuration validation ---------------------------------------------

  defp recipient_errors(config, field, required?) do
    case normalize_recipients(Map.get(config, field)) do
      {:ok, []} when required? ->
        [config_error(field, "is required and must list at least one recipient address")]

      {:ok, _recipients} ->
        []

      {:error, message} ->
        [config_error(field, message)]
    end
  end

  defp from_errors(config) do
    case Map.get(config, "from") do
      nil ->
        []

      value ->
        case normalize_address(value) do
          {:ok, _address} -> []
          {:error, message} -> [config_error("from", message)]
        end
    end
  end

  defp subject_prefix_errors(config) do
    case Map.get(config, "subject_prefix") do
      nil ->
        []

      value when is_binary(value) ->
        if header_safe?(value) do
          []
        else
          [config_error("subject_prefix", "must not contain a carriage return or a line feed")]
        end

      _other ->
        [config_error("subject_prefix", "must be a string")]
    end
  end

  defp forbidden_key_errors(config) do
    case forbidden_keys(config) do
      [] -> []
      keys -> [config_error(hd(keys), forbidden_key_message(keys))]
    end
  end

  defp forbidden_keys(config) do
    Enum.filter(@forbidden_config_keys, &Map.has_key?(config, &1))
  end

  defp forbidden_key_message(keys) do
    "#{Enum.join(keys, ", ")} #{verb(keys)} deployment mail configuration, not channel " <>
      "configuration: set SERVICERADAR_MAILER_ADAPTER and the SMTP_RELAY_* environment, or " <>
      "use Settings > Mail. Accepting a relay host and port from a channel row would let a " <>
      "notification be aimed at an arbitrary internal service"
  end

  defp verb([_single]), do: "is"
  defp verb(_keys), do: "are"

  defp mailer_errors(opts) do
    case mailer_diagnostic(opts) do
      :ok -> []
      {:error, {_class, message}} -> [config_error(nil, message)]
    end
  end

  defp mailer_diagnostic(opts), do: opts |> resolved_mailer() |> elem(1)

  # `{resolved_config_or_nil, diagnostic}`. The configuration is resolved at
  # most once: `diagnose/0` would resolve it again, and each resolution is a
  # settings read plus a credential-broker call.
  defp resolved_mailer(opts) do
    case Keyword.fetch(opts, :mailer_diagnostic) do
      {:ok, diagnostic} ->
        {Keyword.get(opts, :mailer_config), diagnostic}

      :error ->
        case Keyword.fetch(opts, :mailer_config) do
          {:ok, config} -> {config, OutboundMail.diagnose(config)}
          :error -> resolve_deployment_mailer()
        end
    end
  end

  defp resolve_deployment_mailer do
    resolved = OutboundMail.effective_config()

    config =
      case resolved do
        {:ok, config} -> config
        {:error, _reason} -> nil
      end

    # `diagnose/1` classifies the resolution result itself, so the sentence an
    # operator reads is the mailer module's in every case and the settings row
    # is read once.
    {config, OutboundMail.diagnose(resolved)}
  end

  # --- addresses ------------------------------------------------------------

  defp normalize_recipients(nil), do: {:ok, []}

  # Empty textareas arrive as "" or [""]. Optional fields (cc/bcc) must treat
  # that as "no recipients", not as a blank address.
  defp normalize_recipients(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, []}
      trimmed -> normalize_recipients([trimmed])
    end
  end

  defp normalize_recipients(values) when is_list(values) do
    values = Enum.reject(values, &blank_recipient?/1)

    cond do
      values == [] ->
        {:ok, []}

      length(values) > @max_recipients ->
        {:error, "must list at most #{@max_recipients} recipients"}

      true ->
        Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
          case normalize_address(value) do
            {:ok, address} -> {:cont, {:ok, acc ++ [address]}}
            {:error, message} -> {:halt, {:error, message}}
          end
        end)
    end
  end

  defp normalize_recipients(_value) do
    {:error, "must be a list of recipient addresses"}
  end

  defp blank_recipient?(nil), do: true

  defp blank_recipient?(value) when is_binary(value), do: String.trim(value) == ""

  defp blank_recipient?(value) when is_map(value) and not is_struct(value) do
    value = stringify(value)
    address = Map.get(value, "email") || Map.get(value, "address")
    is_nil(address) or (is_binary(address) and String.trim(address) == "")
  end

  defp blank_recipient?(_value), do: false

  defp normalize_address(value) when is_binary(value) do
    validate_address(value)
  end

  defp normalize_address(value) when is_map(value) and not is_struct(value) do
    value = stringify(value)
    address = Map.get(value, "email") || Map.get(value, "address")
    name = presence(Map.get(value, "name"))

    with {:ok, address} <- validate_address(address) do
      cond do
        is_nil(name) -> {:ok, address}
        header_safe?(name) -> {:ok, {name, address}}
        true -> {:error, "name must not contain a carriage return or a line feed"}
      end
    end
  end

  defp normalize_address([name, address]) when is_binary(name) and is_binary(address) do
    normalize_address(%{"name" => name, "email" => address})
  end

  defp normalize_address(_value) do
    {:error, "must be an address string or a map with an email key"}
  end

  defp validate_address(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, "must not be blank"}

      byte_size(trimmed) > @max_address_bytes ->
        {:error, "must be at most #{@max_address_bytes} bytes"}

      not header_safe?(trimmed) ->
        {:error, "must not contain a carriage return or a line feed"}

      not valid_address?(trimmed) ->
        {:error, "must be an email address of the form name@example.com"}

      true ->
        {:ok, trimmed}
    end
  end

  defp validate_address(_value), do: {:error, "must be an email address"}

  # Deliberately conservative rather than RFC-complete: an address that this
  # rejects is a configuration mistake far more often than it is a legitimate
  # quoted local part, and the cost of being wrong in the other direction is a
  # header this transport did not intend to write.
  defp valid_address?(value) do
    case String.split(value, "@") do
      [local, domain] ->
        local != "" and domain != "" and
          not String.contains?(value, [" ", "\t", ",", ";", "<", ">"]) and
          String.contains?(domain, ".") and
          not String.starts_with?(domain, ".") and
          not String.ends_with?(domain, ".")

      _other ->
        false
    end
  end

  defp header_safe?(value) when is_binary(value), do: not String.contains?(value, ["\r", "\n"])
  defp header_safe?(_value), do: false

  defp sanitize_header(value) when is_binary(value) do
    value
    |> String.replace(~r/[\x00-\x1f\x7f]+/, " ")
    |> String.trim()
  end

  # --- results --------------------------------------------------------------

  defp invalid_request do
    Result.permanent_failure("invalid_request",
      error_message: "expected a %Transport.Request{}",
      result_summary: summary(%{})
    )
  end

  # A transport must never take the dispatcher down, and must never put an
  # exception message - which can carry an address list or a relay password -
  # into a persisted field. Only the exception's module name survives.
  defp exception_result(kind, reason) do
    name = exception_name(reason)

    Result.retryable_failure("transport_exception",
      error_message: "the email transport raised #{kind}: #{name}",
      result_summary: summary(%{"exception" => name})
    )
  end

  defp exception_name(%module{}), do: inspect(module)
  defp exception_name(reason) when is_atom(reason), do: inspect(reason)
  defp exception_name({reason, _detail}) when is_atom(reason), do: inspect(reason)
  defp exception_name(_reason), do: "unknown"

  defp summary(extra) do
    %{"transport" => "email"}
    |> Map.merge(extra)
    |> compact()
    |> ActionRedaction.redact()
  end

  defp config_error(field, message), do: %{field: field, message: message}

  # --- helpers --------------------------------------------------------------

  # Normalised the way `Transports.HTTP` normalises it, so the values scrubbed
  # here are the same set every other transport scrubs.
  defp sensitive_values(%Request{secrets: secrets}) when is_map(secrets) do
    HTTP.sensitive_values(sensitive_values: Map.values(secrets))
  end

  defp sensitive_values(_request), do: []

  defp provider_message_id(%{id: id}) when is_binary(id), do: presence(id)
  defp provider_message_id(%{"id" => id}) when is_binary(id), do: presence(id)
  defp provider_message_id(%{message_id: id}) when is_binary(id), do: presence(id)
  defp provider_message_id(_metadata), do: nil

  defp header(%Swoosh.Email{headers: headers}, name) when is_map(headers) do
    presence(Map.get(headers, name))
  end

  defp header(_email, _name), do: nil

  defp stringify(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {stringify_key(key), value} end)
  end

  defp stringify(_value), do: %{}

  defp stringify_key(key) when is_binary(key), do: key
  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key), do: inspect(key)

  defp put_present(fields, _key, nil), do: fields
  defp put_present(fields, _key, []), do: fields
  defp put_present(fields, key, value), do: Keyword.put(fields, key, value)

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  # Sliced by characters rather than bytes: `binary_part/3` can cut a multi-byte
  # codepoint in half, and the resulting invalid UTF-8 fails JSON encoding when
  # the summary is persisted - turning a truncated message into a lost one.
  defp truncate(value, limit) when is_binary(value) do
    if String.length(value) <= limit, do: value, else: String.slice(value, 0, limit)
  end

  defp truncate(value, _limit), do: value
end
