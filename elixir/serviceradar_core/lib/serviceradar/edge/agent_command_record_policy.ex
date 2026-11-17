defmodule ServiceRadar.Edge.AgentCommandRecordPolicy do
  @moduledoc """
  What a `platform.agent_commands` row may hold.

  A command row is short-lived audit and troubleshooting state, readable by any
  operator. It is not a credential store: credential material belongs in
  `platform.network_credential_secrets`. The agent receives the real command
  payload from memory at dispatch (`AgentCommandBus`); only the managed
  certificate redispatch reads a payload back from its row. So the row can, and
  must, hold a redacted copy.

  Every rule here is applied in one place on each side:

    * `persisted_payload/2` and `persisted_context/2`, from `AgentCommandBus`,
      before a command row is written, and from the `AgentCommand` create
      actions (`redact_changeset/2`) for rows created without the bus;
    * `scrub_agent_report/1`, from `AgentCommands.PersistenceWorker`, before an
      agent's acknowledgement, progress or result is written or handed to any
      consumer;
    * `scrub_row/1`, from `AgentCommandRecordScrubWorker`, for rows written
      before these rules existed.

  The rules, for every command type:

    1. A key declared sensitive for the command type (`@sensitive_keys`) is
       replaced. A URL keeps its origin (`rtsps://host:port/[redacted]`), so an
       operator can still see which device it pointed at; any other value
       becomes `"REDACTED"`, the marker `CredentialRedactor` already stores.
    2. A key whose name ends in `token`, `secret`, `password`, `passwd` or
       `passphrase` is replaced with `"REDACTED"` whatever the command type,
       unless its value is a secret reference. This is the default for a
       command type that declares nothing, so a new type cannot forget it.
    3. `ServiceRadar.Credentials.CredentialRedactor` runs over a payload, as it
       already does at the transmit gate.
    4. Every URL inside a string loses its userinfo, query and fragment
       (`SecretTextScrubber.scrub_value/1`). Keys named `*url` are not replaced
       wholesale: some persisted payloads are verified against a rebuilt
       request (the AWX callback contract compares `base_url`), and a URL
       without userinfo or query carries no secret by itself. A type whose URL
       path is itself secret, such as a UniFi Protect RTSPS alias, declares
       the key under rule 1. A type listed in `@authorized_body_types` keeps
       its URLs whole, because its args must equal the request body the
       credential broker authorized; its inputs cannot hold userinfo.

  Agent-reported text (`message`, `failure_reason`) is reduced with
  `SecretTextScrubber.scrub_text/1`, which keeps only a URL's origin.
  """

  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Credentials.SecretTextScrubber

  # The marker CredentialRedactor and the northbound dispatcher already store.
  @redacted "REDACTED"

  # Per command type, the payload and context keys whose whole value is
  # secret. camera.open_relay: the stream URL carries a username and password
  # or, for UniFi Protect, an alias token in its path; the relay lease token is
  # only meaningful to the agent that receives it.
  @sensitive_keys %{
    "camera.open_relay" => ~w(source_url lease_token)
  }

  # Command types whose payload args are validated non-secret launch inputs,
  # bound byte for byte to `authorized_request_body_b64`, whose SHA-256 is the
  # credential broker's `allow` policy. A URL in them keeps its query and
  # fragment so the stored args say what the stored body authorized; a URL
  # with userinfo is refused before dispatch (`VariableSchema` and
  # `AwxClient`). Key-based redaction still applies to these types.
  @authorized_body_types ~w(awx.launch_job)

  @sensitive_suffix_pattern ~r/(?:\A|_)(?:token|secret|password|passwd|passphrase)\z/

  @doc "The payload a command row may hold for a command type."
  @spec persisted_payload(String.t(), term()) :: term()
  def persisted_payload(command_type, payload) when is_map(payload) or is_list(payload) do
    command_type
    |> redact_declared_and_suffixed(payload)
    |> CredentialRedactor.redact()
    |> scrub_urls(command_type)
  end

  def persisted_payload(_command_type, payload), do: payload

  @doc """
  The context a command row may hold, and that is handed to the control session.

  CredentialRedactor is not applied here: it rebuilds every map it visits, and
  a context, unlike a JSON payload, may carry structs.
  """
  @spec persisted_context(String.t(), term()) :: term()
  def persisted_context(command_type, context) when is_map(context) or is_list(context) do
    command_type
    |> redact_declared_and_suffixed(context)
    |> scrub_urls(command_type)
  end

  def persisted_context(_command_type, context), do: context

  @doc """
  Whether a value read back from a command row is what the row holds for
  `expected`, the value rebuilt at result time. A stored payload or context
  is never the raw value, so every comparison of the two goes through here.
  """
  @spec matches_persisted?(:payload | :context, String.t(), term(), term()) :: boolean()
  def matches_persisted?(:payload, command_type, stored, expected),
    do: stored == persisted_payload(command_type, expected)

  def matches_persisted?(:context, command_type, stored, expected),
    do: stored == persisted_context(command_type, expected)

  @doc """
  Applies `persisted_payload/2` and `persisted_context/2` to a create
  changeset, for rows created through the `AgentCommand` resource rather than
  the command bus (managed certificate commands).
  """
  @spec redact_changeset(Ash.Changeset.t(), term()) :: Ash.Changeset.t()
  def redact_changeset(changeset, _context) do
    command_type = Ash.Changeset.get_attribute(changeset, :command_type)

    Enum.reduce(
      [payload: &persisted_payload/2, context: &persisted_context/2],
      changeset,
      fn {attribute, redact}, acc ->
        case Ash.Changeset.get_attribute(acc, attribute) do
          nil ->
            acc

          value ->
            Ash.Changeset.force_change_attribute(acc, attribute, redact.(command_type, value))
        end
      end
    )
  end

  @doc """
  An agent's acknowledgement, progress or result report with its free text and
  payload strings scrubbed. Only fields that change are rewritten, so a report
  with nothing to remove is returned unchanged.
  """
  @spec scrub_agent_report(term()) :: term()
  def scrub_agent_report(report) when is_map(report) do
    report
    |> update_present([:message, "message"], &SecretTextScrubber.scrub_text/1)
    |> update_present([:failure_reason, "failure_reason"], &SecretTextScrubber.scrub_text/1)
    |> update_present([:payload, "payload"], &scrub_reported_payload/1)
  end

  def scrub_agent_report(report), do: report

  @doc """
  A stored command row (string-keyed columns) with every rule applied, for the
  one-time cleanup of rows written before these rules existed.
  """
  @spec scrub_row(map()) :: map()
  def scrub_row(%{"command_type" => command_type} = row) do
    row
    |> update_present(["payload"], &persisted_payload(command_type, &1))
    |> update_present(["context"], &persisted_context(command_type, &1))
    |> update_present(["message", "failure_reason"], &SecretTextScrubber.scrub_text/1)
    |> update_present(["result_payload", "progress_payload"], &SecretTextScrubber.scrub_value/1)
  end

  defp scrub_urls(value, command_type) when command_type in @authorized_body_types, do: value
  defp scrub_urls(value, _command_type), do: SecretTextScrubber.scrub_value(value)

  defp redact_declared_and_suffixed(command_type, value),
    do: redact_keys(value, Map.get(@sensitive_keys, command_type, []))

  defp redact_keys(map, declared) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, nested} ->
      name = normalize_key(key)

      cond do
        name in declared -> {key, redact_declared(nested)}
        sensitive_suffix?(name) and material?(nested) -> {key, @redacted}
        true -> {key, redact_keys(nested, declared)}
      end
    end)
  end

  defp redact_keys(list, declared) when is_list(list),
    do: Enum.map(list, &redact_keys(&1, declared))

  defp redact_keys(value, _declared), do: value

  defp redact_declared(nil), do: nil
  defp redact_declared(@redacted), do: @redacted

  defp redact_declared(value) when is_binary(value) do
    if String.contains?(value, "://"),
      do: SecretTextScrubber.redacted_url(value),
      else: @redacted
  end

  defp redact_declared(_value), do: @redacted

  defp sensitive_suffix?(name), do: Regex.match?(@sensitive_suffix_pattern, name)

  # A `nil`, a flag or an already-redacted value carries no material, and a
  # secret reference is how material is meant to travel.
  defp material?(@redacted), do: false

  defp material?(value) when is_binary(value), do: value != "" and not secret_ref?(value)

  defp material?(value), do: is_map(value) or is_list(value)

  defp secret_ref?(value), do: String.starts_with?(value, ["secretref:", "credentialref:"])

  defp normalize_key(key),
    do: key |> to_string() |> String.downcase() |> String.trim() |> String.replace("-", "_")

  # A JSON-string payload is scrubbed as JSON so its structure cannot change,
  # and keeps its original bytes when nothing was removed.
  defp scrub_reported_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} ->
        scrubbed = SecretTextScrubber.scrub_value(decoded)
        if scrubbed == decoded, do: payload, else: Jason.encode!(scrubbed)

      {:error, _reason} ->
        SecretTextScrubber.scrub_text(payload)
    end
  end

  defp scrub_reported_payload(payload), do: SecretTextScrubber.scrub_value(payload)

  defp update_present(map, keys, fun) do
    Enum.reduce(keys, map, fn key, acc ->
      case Map.fetch(acc, key) do
        {:ok, value} when not is_nil(value) ->
          scrubbed = fun.(value)
          if scrubbed == value, do: acc, else: Map.put(acc, key, scrubbed)

        _absent ->
          acc
      end
    end)
  end
end
