defmodule ServiceRadar.EventWriter.FalcoDecomposition do
  @moduledoc """
  Shared Falco runtime-event decomposition for direct ingestion and log promotion.

  The direct Falco processor and the generic log-promotion path both need the same
  context, diagnostics, observables, finding identity, and ATT&CK parsing. Keeping
  that shape here prevents the two paths from drifting.
  """

  import Bitwise

  alias ServiceRadar.EventWriter.OCSF

  @finding_classes MapSet.new([
                     OCSF.class_vulnerability_finding(),
                     OCSF.class_compliance_finding(),
                     OCSF.class_detection_finding(),
                     OCSF.class_application_security_posture_finding()
                   ])

  @tactic_names %{
    "reconnaissance" => {"TA0043", "Reconnaissance"},
    "resource_development" => {"TA0042", "Resource Development"},
    "initial_access" => {"TA0001", "Initial Access"},
    "execution" => {"TA0002", "Execution"},
    "persistence" => {"TA0003", "Persistence"},
    "privilege_escalation" => {"TA0004", "Privilege Escalation"},
    "defense_evasion" => {"TA0005", "Defense Evasion"},
    "credential_access" => {"TA0006", "Credential Access"},
    "discovery" => {"TA0007", "Discovery"},
    "lateral_movement" => {"TA0008", "Lateral Movement"},
    "collection" => {"TA0009", "Collection"},
    "command_and_control" => {"TA0011", "Command and Control"},
    "exfiltration" => {"TA0010", "Exfiltration"},
    "impact" => {"TA0040", "Impact"}
  }

  @spec output_fields(map()) :: map()
  def output_fields(payload) when is_map(payload) do
    payload["output_fields"]
    |> normalize_map()
    |> Map.merge(normalize_map(payload["custom_fields"]))
    |> Map.merge(normalize_map(payload["templated_fields"]))
  end

  def output_fields(_payload), do: %{}

  @spec context(map(), map(), keyword()) :: map()
  def context(falco, output_fields, opts \\ []) do
    hostname =
      Keyword.get(opts, :hostname) ||
        normalize_string(get_nested_value(falco, "hostname")) ||
        falco_field(output_fields, ["k8s.node.name", "host.name", "evt.hostname"])

    %{
      "rule" => normalize_string(get_nested_value(falco, "rule")),
      "priority" => normalize_string(get_nested_value(falco, "priority")),
      "hostname" => hostname,
      "namespace" => Keyword.get(opts, :namespace) || falco_field(output_fields, ["k8s.ns.name"]),
      "pod" => Keyword.get(opts, :pod) || falco_field(output_fields, ["k8s.pod.name"]),
      "container" =>
        Keyword.get(opts, :container) || falco_field(output_fields, ["container.name"]),
      "container_id" =>
        Keyword.get(opts, :container_id) || falco_field(output_fields, ["container.id"])
    }
  end

  @spec class_uid(map(), map()) :: pos_integer()
  def class_uid(falco, output_fields \\ %{}) do
    override =
      falco
      |> class_override(output_fields)
      |> validate_finding_class()

    override || class_uid_from_tags(tags(falco))
  end

  @spec finding_info(map(), map(), String.t() | nil) :: map()
  def finding_info(falco, output_fields, subject \\ nil) do
    context = context(falco, output_fields)
    class_uid = class_uid(falco, output_fields)

    dimensions =
      compact_map(%{
        "rule" => context["rule"],
        "source" => normalize_string(get_nested_value(falco, "source")),
        "subject" => subject,
        "class_uid" => class_uid,
        "hostname" => context["hostname"],
        "namespace" => context["namespace"],
        "pod" => context["pod"],
        "container_id" => context["container_id"]
      })

    group_key = stable_json(dimensions)
    uid = deterministic_uuid("falco:finding:#{group_key}")

    compact_map(%{
      "uid" => uid,
      "group_uid" => uid,
      "group_key" => group_key,
      "title" => context["rule"] || "Falco runtime finding",
      "type" => "Falco Rule",
      "type_id" => 99,
      "source" => "falco",
      "dimensions" => dimensions
    })
  end

  @spec diagnostics(map(), map(), map()) :: map()
  def diagnostics(falco, output_fields, context) do
    compact_map(%{
      "rule" => %{
        "name" => context["rule"],
        "priority" => context["priority"],
        "uuid" => normalize_string(get_nested_value(falco, "uuid")),
        "source" => normalize_string(get_nested_value(falco, "source")),
        "tags" => tags(falco),
        "references" => references(falco, output_fields)
      },
      "host" => %{"name" => context["hostname"]},
      "process" => process_diagnostics(output_fields),
      "parent_process" => parent_process_diagnostics(output_fields),
      "user" => user_diagnostics(output_fields),
      "file" => file_diagnostics(output_fields),
      "network" => network_diagnostics(output_fields),
      "container" =>
        container_diagnostics(output_fields, %{
          "name" => context["container"],
          "id" => context["container_id"]
        }),
      "kubernetes" => %{
        "namespace" => context["namespace"],
        "pod" => context["pod"],
        "node" => falco_field(output_fields, ["k8s.node.name"])
      },
      "event" => event_diagnostics(output_fields, falco),
      "attribution" =>
        attribution(
          context["namespace"],
          context["pod"],
          context["container"],
          context["container_id"]
        )
    })
  end

  @spec observables(map(), map(), map() | nil) :: [map()]
  def observables(falco, output_fields, context \\ nil) do
    context = context || context(falco, output_fields)
    network = network_diagnostics(output_fields)

    Enum.reject(
      [
        maybe_observable(context["hostname"], "Hostname", 1),
        maybe_observable(context["rule"], "Falco Rule", 99),
        maybe_observable(context["namespace"], "Kubernetes Namespace", 99),
        maybe_observable(context["pod"], "Kubernetes Pod", 99),
        maybe_observable(context["container"], "Container Name", 99),
        maybe_observable(context["container_id"], "Container ID", 99),
        maybe_observable(network["source_ip"], "Source IP", 2),
        maybe_observable(network["destination_ip"], "Destination IP", 2),
        maybe_observable(network["remote_ip"], "Remote IP", 2)
      ],
      &is_nil/1
    )
  end

  @spec tags(map()) :: [String.t()]
  def tags(falco) when is_map(falco), do: normalize_tags(get_nested_value(falco, "tags"))
  def tags(_falco), do: []

  @spec attacks(map(), map()) :: [map()]
  def attacks(falco, output_fields \\ %{}) do
    values =
      [
        tags(falco),
        falco_field(output_fields, ["falco.mitre.tactic", "mitre.tactic", "attack.tactic"]),
        falco_field(output_fields, [
          "falco.mitre.technique",
          "mitre.technique",
          "attack.technique",
          "rule.mitre.technique"
        ])
      ]
      |> List.flatten()
      |> Enum.map(&normalize_string/1)
      |> Enum.reject(&is_nil/1)

    techniques =
      values
      |> Enum.flat_map(&extract_technique_ids/1)
      |> Enum.uniq()

    tactic =
      values
      |> Enum.map(&extract_tactic/1)
      |> Enum.find(& &1)

    cond do
      techniques != [] ->
        Enum.map(techniques, fn technique ->
          compact_map(%{
            "tactic" => tactic && tactic_map(tactic),
            "technique" => %{"uid" => technique}
          })
        end)

      tactic ->
        [compact_map(%{"tactic" => tactic_map(tactic)})]

      true ->
        []
    end
  end

  @spec compact_map(map()) :: map()
  def compact_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      value = compact_value(value)

      if empty_value?(value) do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  @spec falco_field(map(), [String.t()]) :: term()
  def falco_field(output_fields, keys) do
    Enum.reduce_while(keys, nil, fn key, _acc ->
      case falco_value(get_nested_value(output_fields, key)) do
        nil -> {:cont, nil}
        value -> {:halt, value}
      end
    end)
  end

  @spec get_nested_value(map() | nil, String.t()) :: term()
  def get_nested_value(map, key) when is_map(map) and is_binary(key) do
    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      String.contains?(key, ".") ->
        key
        |> String.split(".")
        |> Enum.reduce_while(map, fn part, acc ->
          if is_map(acc) and Map.has_key?(acc, part) do
            {:cont, Map.get(acc, part)}
          else
            {:halt, nil}
          end
        end)

      true ->
        nil
    end
  end

  def get_nested_value(_map, _key), do: nil

  defp class_override(falco, output_fields) do
    override_int(get_nested_value(falco, "ocsf_class_uid")) ||
      override_int(get_nested_value(falco, "class_uid")) ||
      override_int(get_nested_value(output_fields, "falco.ocsf.class_uid")) ||
      override_int(get_nested_value(output_fields, "ocsf.class_uid"))
  end

  defp override_int(value) when is_integer(value), do: value

  defp override_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      {int, _rest} -> int
      :error -> nil
    end
  end

  defp override_int(_value), do: nil

  defp validate_finding_class(class_uid) when is_integer(class_uid) do
    if MapSet.member?(@finding_classes, class_uid), do: class_uid
  end

  defp validate_finding_class(_class_uid), do: nil

  defp class_uid_from_tags(tags) do
    normalized = Enum.map(tags, &String.downcase/1)

    cond do
      Enum.any?(normalized, &vulnerability_tag?/1) ->
        OCSF.class_vulnerability_finding()

      Enum.any?(normalized, &compliance_tag?/1) ->
        OCSF.class_compliance_finding()

      Enum.any?(normalized, &posture_tag?/1) ->
        OCSF.class_application_security_posture_finding()

      true ->
        OCSF.class_detection_finding()
    end
  end

  defp vulnerability_tag?(tag) do
    String.contains?(tag, "vulnerability") or String.contains?(tag, "vuln") or
      String.contains?(tag, "cve") or String.contains?(tag, "cvss")
  end

  defp compliance_tag?(tag) do
    String.contains?(tag, "compliance") or String.starts_with?(tag, "cis") or
      String.starts_with?(tag, "pci") or String.starts_with?(tag, "nist") or
      String.starts_with?(tag, "soc2") or String.starts_with?(tag, "gdpr")
  end

  defp posture_tag?(tag) do
    String.contains?(tag, "posture") or String.contains?(tag, "configuration") or
      String.contains?(tag, "misconfiguration") or String.contains?(tag, "hardening") or
      String.starts_with?(tag, "config")
  end

  defp extract_technique_ids(value) do
    ~r/\bT\d{4}(?:\.\d{3})?\b/i
    |> Regex.scan(value)
    |> List.flatten()
    |> Enum.map(&String.upcase/1)
  end

  defp extract_tactic(value) do
    downcased = String.downcase(value)

    cond do
      match = Regex.run(~r/\bTA\d{4}\b/i, value) ->
        {String.upcase(List.first(match)), nil}

      String.starts_with?(downcased, "mitre_") ->
        downcased
        |> String.replace_prefix("mitre_", "")
        |> tactic_from_name()

      true ->
        downcased
        |> String.replace(~r/^(attack|mitre)[.:_-](tactic[.:_-])?/, "")
        |> tactic_from_name()
    end
  end

  defp tactic_from_name(name) do
    key =
      name
      |> String.replace("-", "_")
      |> String.replace(".", "_")
      |> String.trim("_")

    Map.get(@tactic_names, key)
  end

  defp tactic_map({uid, nil}), do: compact_map(%{"uid" => uid})
  defp tactic_map({uid, name}), do: compact_map(%{"uid" => uid, "name" => name})

  defp process_diagnostics(output_fields) do
    compact_map(%{
      "name" => falco_field(output_fields, ["proc.name"]),
      "short_name" => falco_field(output_fields, ["proc.sname"]),
      "executable" => falco_field(output_fields, ["proc.exe", "proc.exepath"]),
      "executable_path" => falco_field(output_fields, ["proc.exepath"]),
      "command" => falco_field(output_fields, ["proc.cmdline", "proc.args"]),
      "cwd" => falco_field(output_fields, ["proc.cwd"]),
      "tty" => falco_field(output_fields, ["proc.tty"]),
      "pid" => falco_field(output_fields, ["proc.pid"]),
      "executable_flags" =>
        compact_map(%{
          "upper_layer" => falco_field(output_fields, ["proc.is_exe_upper_layer"]),
          "from_memfd" => falco_field(output_fields, ["proc.is_exe_from_memfd"]),
          "from_disk" => falco_field(output_fields, ["proc.is_exe_from_disk"]),
          "lower_layer" => falco_field(output_fields, ["proc.is_exe_lower_layer"]),
          "evt_flags" => falco_field(output_fields, ["evt.arg.flags"])
        })
    })
  end

  defp parent_process_diagnostics(output_fields) do
    compact_map(%{
      "name" => falco_field(output_fields, ["proc.pname"]),
      "ancestor" => falco_field(output_fields, ["proc.aname[2]", "proc.aname[3]"])
    })
  end

  defp user_diagnostics(output_fields) do
    compact_map(%{
      "name" => falco_field(output_fields, ["user.name"]),
      "uid" => falco_field(output_fields, ["user.uid"]),
      "login_uid" => falco_field(output_fields, ["user.loginuid"])
    })
  end

  defp file_diagnostics(output_fields) do
    compact_map(%{
      "name" => falco_field(output_fields, ["fd.name", "evt.arg.path", "evt.arg.name"]),
      "directory" => falco_field(output_fields, ["fd.directory"]),
      "type" => falco_field(output_fields, ["fd.type"]),
      "num" => falco_field(output_fields, ["fd.num"]),
      "flags" => falco_field(output_fields, ["evt.arg.flags", "fd.flags"])
    })
  end

  defp network_diagnostics(output_fields) do
    compact_map(%{
      "source_ip" => falco_field(output_fields, ["fd.sip", "evt.arg.sip"]),
      "source_port" => falco_field(output_fields, ["fd.sport", "evt.arg.sport"]),
      "destination_ip" => falco_field(output_fields, ["fd.dip", "evt.arg.dip"]),
      "destination_port" => falco_field(output_fields, ["fd.dport", "evt.arg.dport"]),
      "l4_protocol" => falco_field(output_fields, ["fd.l4proto"]),
      "remote_ip" => falco_field(output_fields, ["fd.rip"]),
      "remote_port" => falco_field(output_fields, ["fd.rport"])
    })
  end

  defp container_diagnostics(output_fields, context) do
    compact_map(%{
      "id" => context["id"],
      "name" => context["name"],
      "image" => falco_field(output_fields, ["container.image"]),
      "image_repository" => falco_field(output_fields, ["container.image.repository"]),
      "image_tag" => falco_field(output_fields, ["container.image.tag"]),
      "image_digest" => falco_field(output_fields, ["container.image.digest"])
    })
  end

  defp event_diagnostics(output_fields, falco) do
    compact_map(%{
      "type" => falco_field(output_fields, ["evt.type"]),
      "time" =>
        falco_field(output_fields, ["evt.time"]) ||
          normalize_string(get_nested_value(falco, "time")),
      "flags" => falco_field(output_fields, ["evt.arg.flags"])
    })
  end

  defp attribution(namespace, pod, container, container_id) do
    status =
      cond do
        present?(namespace) and present?(pod) ->
          "resolved"

        present?(namespace) or present?(pod) or present?(container) or present?(container_id) ->
          "partial"

        true ->
          "missing"
      end

    missing =
      Enum.reject(
        [
          if(present?(namespace), do: nil, else: "kubernetes.namespace"),
          if(present?(pod), do: nil, else: "kubernetes.pod")
        ],
        &is_nil/1
      )

    compact_map(%{
      "status" => status,
      "missing" => missing
    })
  end

  defp references(falco, output_fields) do
    [
      get_nested_value(falco, "rule_url"),
      get_nested_value(falco, "rule_uri"),
      get_nested_value(falco, "url"),
      get_nested_value(output_fields, "falco.rule.url"),
      get_nested_value(output_fields, "falco.rule_uri")
    ]
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp maybe_observable(nil, _type, _type_id), do: nil
  defp maybe_observable(value, type, type_id), do: OCSF.build_observable(value, type, type_id)

  defp falco_value(value) when is_binary(value), do: normalize_string(value)
  defp falco_value(value) when value in [nil, "", []], do: nil
  defp falco_value(value), do: value

  defp compact_value(value) when is_map(value), do: compact_map(value)

  defp compact_value(value) when is_list(value) do
    value
    |> Enum.map(&compact_value/1)
    |> Enum.reject(&empty_value?/1)
  end

  defp compact_value(value), do: value

  defp empty_value?(nil), do: true
  defp empty_value?(""), do: true
  defp empty_value?([]), do: true
  defp empty_value?(value) when is_map(value), do: map_size(value) == 0
  defp empty_value?(_value), do: false

  defp present?(value), do: not empty_value?(value)

  defp stable_json(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Map.new()
    |> Jason.encode!()
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}

  defp normalize_tags(value) when is_list(value) do
    value
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_tags(value) when is_binary(value) do
    value
    |> String.split([",", " "], trim: true)
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_tags(_value), do: []

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp deterministic_uuid(key) do
    <<a1::32, a2::16, a3::16, a4::16, a5::48, _rest::binary>> = :crypto.hash(:sha256, key)
    versioned_a3 = a3 |> band(0x0FFF) |> bor(0x4000)
    versioned_a4 = a4 |> band(0x3FFF) |> bor(0x8000)

    "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b"
    |> :io_lib.format([a1, a2, versioned_a3, versioned_a4, a5])
    |> IO.iodata_to_binary()
  end
end
