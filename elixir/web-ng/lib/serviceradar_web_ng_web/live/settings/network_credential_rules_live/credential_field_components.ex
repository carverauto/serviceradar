defmodule ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLive.CredentialFieldComponents do
  @moduledoc """
  Renders the inputs a credential descriptor declares.

  The create and rotate forms both draw their fields from an auth method's
  descriptor, so they share this component rather than each interpreting
  `control`, `options` and `applies_when` on its own. Which fields are shown and
  which are mandatory is asked of `CredentialSecretBuilder.applicable_fields/2`,
  the function the server validates a submission with, so the form cannot show
  a rule the server does not enforce.

  Secret fields render with no value attribute and are ignored by later
  patches, so a form change neither echoes a secret nor clears one the
  operator typed. `values/3` is the only way submitted params reach this
  component, and it leaves secret fields out.
  """

  use ServiceRadarWebNGWeb, :html

  alias ServiceRadar.Credentials.CredentialSecretBuilder

  @doc """
  The inputs for `method`, given the non-secret `values` chosen so far.

  `form_name` is the form's param root (`"credential_secret"`), which also
  prefixes each input's DOM id: `credential_secret_fields_<field id>`.
  """
  attr :method, :map, required: true
  attr :form_name, :string, required: true
  attr :values, :map, default: %{}
  attr :errors, :map, default: %{}
  attr :rest, :global

  def descriptor_fields(assigns) do
    assigns =
      assign(
        assigns,
        :fields,
        CredentialSecretBuilder.applicable_fields(assigns.method, assigns.values)
      )

    ~H"""
    <%!-- Keyed by field id so switching a choice re-renders only the fields it
    adds or removes. A password already typed into a field that stays is not
    touched; one typed into a field that goes away is gone with it. --%>
    <div :for={{field, required?} <- @fields} :key={field["id"]} class="contents">
      <.input
        :if={field["control"] == "select"}
        id={"#{@form_name}_fields_#{field["id"]}"}
        name={"#{@form_name}[fields][#{field["id"]}]"}
        type="select"
        label={field["label"]}
        options={select_options(field)}
        value={Map.get(@values, field["id"], "")}
        prompt={select_prompt(field, @values)}
        required={required?}
        errors={field_errors(@errors, field)}
        {@rest}
      />
      <.input
        :if={field["control"] != "select" and field["secret"]}
        id={"#{@form_name}_fields_#{field["id"]}"}
        name={"#{@form_name}[fields][#{field["id"]}]"}
        type={input_type(field)}
        label={field["label"]}
        value={nil}
        phx-update="ignore"
        placeholder={field["placeholder"]}
        minlength={field["min_length"]}
        maxlength={field["max_length"]}
        required={required?}
        autocomplete="new-password"
        errors={field_errors(@errors, field)}
        {@rest}
      />
      <.input
        :if={field["control"] != "select" and !field["secret"]}
        id={"#{@form_name}_fields_#{field["id"]}"}
        name={"#{@form_name}[fields][#{field["id"]}]"}
        type={input_type(field)}
        label={field["label"]}
        value={Map.get(@values, field["id"], "")}
        placeholder={field["placeholder"]}
        minlength={field["min_length"]}
        maxlength={field["max_length"]}
        required={required?}
        autocomplete="off"
        errors={field_errors(@errors, field)}
        {@rest}
      />
    </div>
    """
  end

  @doc """
  The non-secret values a form should keep, from the `fields` params it
  submitted.

  A secret field is left out. A field the form did not submit, because the operator
  had switched to a choice that hides it, starts again from the descriptor's
  default when `defaults?` is set. A rotation passes `false`: it must not
  pre-select a protocol the stored credential may not use.
  """
  @spec values(map(), term(), boolean()) :: %{String.t() => String.t()}
  def values(method, submitted, defaults?) do
    submitted = if is_map(submitted), do: submitted, else: %{}

    for field <- method["fields"] || [], !field["secret"], into: %{} do
      {field["id"], kept_value(field, Map.get(submitted, field["id"]), defaults?)}
    end
  end

  defp kept_value(_field, submitted, _defaults?) when is_binary(submitted), do: submitted
  defp kept_value(field, nil, true), do: Map.get(field, "default", "")
  defp kept_value(_field, _submitted, _defaults?), do: ""

  @doc """
  The message for a field the credential builder turned down, as
  `{field id, message}`, or `nil` when `reason` does not name a field.
  """
  @spec field_error(map(), term()) :: {String.t(), String.t()} | nil
  def field_error(method, {reason, field_id})
      when reason in [:missing_credential_field, :invalid_credential_field] and is_binary(field_id) do
    field = Enum.find(method["fields"] || [], &(&1["id"] == field_id)) || %{}
    label = field["label"] || field_id

    {field_id, field_message(reason, field, label)}
  end

  def field_error(_method, _reason), do: nil

  defp field_message(:missing_credential_field, _field, label), do: "#{label} is required"

  defp field_message(:invalid_credential_field, %{"options" => options}, label) when is_list(options),
    do: "#{label} must be one of the listed options"

  defp field_message(:invalid_credential_field, _field, label), do: "#{label} has an invalid length"

  defp select_options(field), do: Enum.map(field["options"] || [], &{&1["label"], &1["value"]})

  # A select shows "nothing chosen" only when that is true: a new credential
  # starts on the descriptor's default, a rotation starts blank. A kept value
  # that is not an option counts as nothing chosen, so a rejected name is not
  # displayed as though the first option had been picked.
  defp select_prompt(field, values) do
    current = Map.get(values, field["id"], "")

    offered = Enum.map(field["options"] || [], & &1["value"])

    if current not in offered, do: "Choose..."
  end

  defp field_errors(errors, field), do: errors |> Map.get(field["id"]) |> List.wrap()

  defp input_type(%{"control" => "textarea"}), do: "textarea"
  defp input_type(%{"control" => "password"}), do: "password"
  defp input_type(%{"secret" => true}), do: "password"
  defp input_type(_field), do: "text"
end
