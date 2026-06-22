defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.MapperForms do
  @moduledoc false
  import Phoenix.Component, only: [to_form: 2]
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.MapperParams

  def mapper_job_to_form(job) do
    %{
      "name" => job.name,
      "description" => job.description || "",
      "enabled" => job.enabled,
      "interval" => job.interval,
      "partition" => job.partition,
      "agent_id" => job.agent_id || "",
      "discovery_mode" => to_string(job.discovery_mode),
      "discovery_type" => to_string(job.discovery_type),
      "concurrency" => job.concurrency,
      "timeout" => job.timeout,
      "retries" => job.retries
    }
  end

  def has_secret_value?(struct, field) do
    case Map.get(struct, field) do
      nil -> false
      "" -> false
      value when is_binary(value) -> byte_size(value) > 0
      _ -> false
    end
  end

  def mapper_unifi_form([]), do: {empty_unifi_form(), false}
  def mapper_unifi_form(%Ash.NotLoaded{}), do: {empty_unifi_form(), false}

  def mapper_unifi_form([controller | _]) do
    form = %{
      "name" => controller.name || "",
      "base_url" => controller.base_url || "",
      "insecure_skip_verify" => controller.insecure_skip_verify || false
    }

    # Check for API key by directly inspecting the struct
    api_key_present = has_secret_value?(controller, :api_key)

    {to_form(form, as: :unifi), api_key_present}
  end

  def mapper_mikrotik_form([]), do: {empty_mikrotik_form(), false}
  def mapper_mikrotik_form(%Ash.NotLoaded{}), do: {empty_mikrotik_form(), false}

  def mapper_mikrotik_form([controller | _]) do
    form = %{
      "name" => controller.name || "",
      "base_url" => controller.base_url || "",
      "username" => controller.username || "",
      "insecure_skip_verify" => controller.insecure_skip_verify || false
    }

    password_present = has_secret_value?(controller, :password)

    {to_form(form, as: :mikrotik), password_present}
  end

  def mapper_mikrotik_fields([]), do: empty_mikrotik_fields()
  def mapper_mikrotik_fields(%Ash.NotLoaded{}), do: empty_mikrotik_fields()

  def mapper_mikrotik_fields([controller | _]) do
    %{
      name: controller.name || "",
      base_url: controller.base_url || "",
      username: controller.username || "",
      insecure_skip_verify: controller.insecure_skip_verify || false,
      password_present: has_secret_value?(controller, :password)
    }
  end

  def empty_unifi_form do
    to_form(
      %{
        "name" => "",
        "base_url" => "",
        "api_key" => "",
        "insecure_skip_verify" => false
      },
      as: :unifi
    )
  end

  def empty_mikrotik_form do
    to_form(
      %{
        "name" => "",
        "base_url" => "",
        "username" => "",
        "password" => "",
        "insecure_skip_verify" => false
      },
      as: :mikrotik
    )
  end

  def empty_mikrotik_fields do
    %{
      name: "",
      base_url: "",
      username: "",
      insecure_skip_verify: false,
      password_present: false
    }
  end

  def normalize_mikrotik_fields(fields) do
    Map.merge(empty_mikrotik_fields(), fields || %{})
  end

  def build_mikrotik_fields_from_params(current, params) do
    params = normalize_boolean(params, "insecure_skip_verify")

    current
    |> normalize_mikrotik_fields()
    |> Map.merge(%{
      name: Map.get(params, "name", current[:name] || ""),
      base_url: Map.get(params, "base_url", current[:base_url] || ""),
      username: Map.get(params, "username", current[:username] || ""),
      insecure_skip_verify:
        Map.get(
          params,
          "insecure_skip_verify",
          current[:insecure_skip_verify] || false
        )
    })
  end

  def seeds_to_text(seeds) do
    Enum.map_join(seeds, "\n", & &1.seed)
  end

  def parse_seeds_text(text) do
    text
    |> String.split(~r/[\n,]+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end
end
