from pathlib import Path
import sys


ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path.cwd()


def rel(path: str) -> Path:
    return ROOT / path


def patch_file(path: Path, replacements):
    if not path.exists():
        return
    text = path.read_text()
    original = text
    for old, new in replacements:
        text = text.replace(old, new)
    if text != original:
        path.write_text(text)


# Patch elixir_uuid to avoid deprecated Bitwise warning.
patch_file(
    rel("deps/elixir_uuid/lib/uuid.ex"),
    [
        ("  use Bitwise, only_operators: true\n", ""),
        ("  import Bitwise\n", ""),
    ],
)

# Patch opentelemetry_api_experimental charlist deprecations under Elixir 1.19.
patch_file(
    rel("deps/opentelemetry_api_experimental/mix.exs"),
    [
        (":file.consult('rebar.config')", ':file.consult(~c"rebar.config")'),
        (
            ":file.consult('src/opentelemetry_api_experimental.app.src')",
            ':file.consult(~c"src/opentelemetry_api_experimental.app.src")',
        ),
    ],
)

# Patch protobuf to avoid struct-update typing warnings under Elixir 1.19.
patch_file(
    rel("deps/protobuf/lib/protobuf/dsl.ex"),
    [
        (
            "  defp cal_packed(props, _syntax), do: %FieldProps{props | packed?: false}\n",
            "  defp cal_packed(%FieldProps{} = props, _syntax), do: %FieldProps{props | packed?: false}\n",
        ),
        (
            "    Enum.reduce(opts, props, fn\n"
            "      {:optional, optional?}, acc ->\n"
            "        %FieldProps{acc | optional?: optional?}\n\n"
            "      {:proto3_optional, proto3_optional?}, acc ->\n"
            "        %FieldProps{acc | proto3_optional?: proto3_optional?}\n\n"
            "      {:required, required?}, acc ->\n"
            "        %FieldProps{acc | required?: required?}\n\n"
            "      {:enum, enum?}, acc ->\n"
            "        %FieldProps{acc | enum?: enum?}\n\n"
            "      {:map, map?}, acc ->\n"
            "        %FieldProps{acc | map?: map?}\n\n"
            "      {:repeated, repeated?}, acc ->\n"
            "        %FieldProps{acc | repeated?: repeated?}\n\n"
            "      {:embedded, embedded}, acc ->\n"
            "        %FieldProps{acc | embedded?: embedded}\n\n"
            "      {:deprecated, deprecated?}, acc ->\n"
            "        %FieldProps{acc | deprecated?: deprecated?}\n\n"
            "      {:packed, packed?}, acc ->\n"
            "        %FieldProps{acc | packed?: packed?}\n\n"
            "      {:type, type}, acc ->\n"
            "        %FieldProps{acc | type: type}\n\n"
            "      {:default, default}, acc ->\n"
            "        %FieldProps{acc | default: default}\n\n"
            "      {:oneof, oneof}, acc ->\n"
            "        %FieldProps{acc | oneof: oneof}\n\n"
            "      {:json_name, json_name}, acc ->\n"
            "        %FieldProps{acc | json_name: json_name}\n"
            "    end)\n",
            "    Enum.reduce(opts, props, fn\n"
            "      {:optional, optional?}, %FieldProps{} = acc ->\n"
            "        %FieldProps{acc | optional?: optional?}\n\n"
            "      {:proto3_optional, proto3_optional?}, %FieldProps{} = acc ->\n"
            "        %FieldProps{acc | proto3_optional?: proto3_optional?}\n\n"
            "      {:required, required?}, %FieldProps{} = acc ->\n"
            "        %FieldProps{acc | required?: required?}\n\n"
            "      {:enum, enum?}, %FieldProps{} = acc ->\n"
            "        %FieldProps{acc | enum?: enum?}\n\n"
            "      {:map, map?}, %FieldProps{} = acc ->\n"
            "        %FieldProps{acc | map?: map?}\n\n"
            "      {:repeated, repeated?}, %FieldProps{} = acc ->\n"
            "        %FieldProps{acc | repeated?: repeated?}\n\n"
            "      {:embedded, embedded}, %FieldProps{} = acc ->\n"
            "        %FieldProps{acc | embedded?: embedded}\n\n"
            "      {:deprecated, deprecated?}, %FieldProps{} = acc ->\n"
            "        %FieldProps{acc | deprecated?: deprecated?}\n\n"
            "      {:packed, packed?}, %FieldProps{} = acc ->\n"
            "        %FieldProps{acc | packed?: packed?}\n\n"
            "      {:type, type}, %FieldProps{} = acc ->\n"
            "        %FieldProps{acc | type: type}\n\n"
            "      {:default, default}, %FieldProps{} = acc ->\n"
            "        %FieldProps{acc | default: default}\n\n"
            "      {:oneof, oneof}, %FieldProps{} = acc ->\n"
            "        %FieldProps{acc | oneof: oneof}\n\n"
            "      {:json_name, json_name}, %FieldProps{} = acc ->\n"
            "        %FieldProps{acc | json_name: json_name}\n"
            "    end)\n",
        ),
    ],
)
patch_file(
    rel("deps/protobuf/lib/protobuf/protoc/generator.ex"),
    [
        (
            "  defp generate_module_definitions(ctx, %Google.Protobuf.FileDescriptorProto{} = desc) do\n",
            "  defp generate_module_definitions(%Context{} = ctx, %Google.Protobuf.FileDescriptorProto{} = desc) do\n",
        ),
    ],
)

# Patch protobuf cli.ex for parse_param functions.
patch_file(
    rel("deps/protobuf/lib/protobuf/protoc/cli.ex"),
    [
        (
            'defp parse_param("plugins=" <> plugins, ctx) do\n',
            'defp parse_param("plugins=" <> plugins, %Context{} = ctx) do\n',
        ),
        (
            'defp parse_param("gen_descriptors=" <> value, ctx) do\n',
            'defp parse_param("gen_descriptors=" <> value, %Context{} = ctx) do\n',
        ),
        (
            'defp parse_param("package_prefix=" <> package, ctx) do\n',
            'defp parse_param("package_prefix=" <> package, %Context{} = ctx) do\n',
        ),
        (
            'defp parse_param("transform_module=" <> module, ctx) do\n',
            'defp parse_param("transform_module=" <> module, %Context{} = ctx) do\n',
        ),
        (
            'defp parse_param("one_file_per_module=" <> value, ctx) do\n',
            'defp parse_param("one_file_per_module=" <> value, %Context{} = ctx) do\n',
        ),
        (
            'defp parse_param("include_docs=" <> value, ctx) do\n',
            'defp parse_param("include_docs=" <> value, %Context{} = ctx) do\n',
        ),
    ],
)

# Patch protobuf message.ex for Context struct updates.
patch_file(
    rel("deps/protobuf/lib/protobuf/protoc/generator/message.ex"),
    [
        ("  defp gen_nested_msgs(ctx, desc) do\n", "  defp gen_nested_msgs(%Context{} = ctx, desc) do\n"),
        ("  defp gen_nested_enums(ctx, desc) do\n", "  defp gen_nested_enums(%Context{} = ctx, desc) do\n"),
        ("  defp get_fields(ctx, desc) do\n", "  defp get_fields(%Context{} = ctx, desc) do\n"),
        (
            "  defp get_field(ctx, %FieldDescriptorProto{} = field_desc, nested_maps, oneofs) do\n",
            "  defp get_field(%Context{} = ctx, %FieldDescriptorProto{} = field_desc, nested_maps, oneofs) do\n",
        ),
        (
            "  defp field_type_name(ctx, %FieldDescriptorProto{type_name: type_name} = field_desc) do\n",
            "  defp field_type_name(%Context{} = ctx, %FieldDescriptorProto{type_name: type_name} = field_desc) do\n",
        ),
        ("  defp nested_maps(ctx, desc) do\n", "  defp nested_maps(%Context{} = ctx, desc) do\n"),
    ],
)

# Patch permit to avoid struct-update typing warnings under Elixir 1.19.
patch_file(
    rel("deps/permit/lib/permit/permissions/disjunctive_normal_form.ex"),
    [
        ("def add_clauses(dnf, clauses) do\n", "def add_clauses(%DNF{} = dnf, clauses) do\n"),
        ("def add_clauses(dnf, clause) do\n", "def add_clauses(%DNF{} = dnf, clause) do\n"),
    ],
)

# Patch protobuf extension.ex for Context struct updates.
patch_file(
    rel("deps/protobuf/lib/protobuf/protoc/generator/extension.ex"),
    [
        (
            "  defp generate_extend_dsl(ctx, %FieldDescriptorProto{} = f, ns) do\n",
            "  defp generate_extend_dsl(%Context{} = ctx, %FieldDescriptorProto{} = f, ns) do\n",
        ),
        (
            "          %Context{\n"
            '            Context.append_comment_path(ctx, "6.#{index}")\n'
            "            | namespace: ctx.namespace ++ [Macro.camelize(desc.name)]\n"
            "          },",
            '          (fn %Context{} = c -> %Context{c | namespace: ctx.namespace ++ [Macro.camelize(desc.name)]} end).(Context.append_comment_path(ctx, "6.#{index}")),',
        ),
    ],
)

# Patch protobuf service.ex for Context struct updates.
patch_file(
    rel("deps/protobuf/lib/protobuf/protoc/generator/service.ex"),
    [
        (
            "  defp generate_service_method(ctx, method) do\n",
            "  defp generate_service_method(%Context{} = ctx, method) do\n",
        ),
    ],
)

patch_file(
    rel("deps/protobuf/lib/protobuf/dsl.ex"),
    [
        (
            "  defp cal_json_name(props), do: %FieldProps{props | json_name: props.name}\n",
            "  defp cal_json_name(%FieldProps{} = props), do: %FieldProps{props | json_name: props.name}\n",
        ),
    ],
)

# Patch delta_crdt warnings/errors under Elixir 1.19.
patch_file(
    rel("deps/delta_crdt/lib/delta_crdt.ex"),
    [
        ("Logger.warn(", "Logger.warning("),
    ],
)
patch_file(
    rel("deps/delta_crdt/lib/delta_crdt/aw_lww_map.ex"),
    [
        ("Logger.warn(", "Logger.warning("),
    ],
)


def patch_delta_crdt_causal(path: Path):
    if not path.exists():
        return
    text = path.read_text()
    original = text
    reverse_target = "diff = reverse_diff(diff)"
    if reverse_target in text:
        text = text.replace(reverse_target, "diff = %Diff{} = reverse_diff(diff)")
    target_fq = "%DeltaCrdt.CausalCrdt.Diff{diff | continuation: truncate(continuation, state.max_sync_size)}"
    if target_fq in text:
        replacement_fq = (
            "diff = case diff do\n"
            "      %DeltaCrdt.CausalCrdt.Diff{} = diff -> diff\n"
            "      _ -> diff\n"
            "    end\n"
            "    %DeltaCrdt.CausalCrdt.Diff{diff | continuation: truncate(continuation, state.max_sync_size)}"
        )
        text = text.replace(target_fq, replacement_fq)
    target_alias = "%Diff{diff | continuation: truncate(continuation, state.max_sync_size)}"
    if target_alias in text:
        replacement_alias = (
            "diff = case diff do\n"
            "      %Diff{} = diff -> diff\n"
            "      _ -> diff\n"
            "    end\n"
            "    %Diff{diff | continuation: truncate(continuation, state.max_sync_size)}"
        )
        text = text.replace(target_alias, replacement_alias)
    if text != original:
        path.write_text(text)


patch_delta_crdt_causal(rel("deps/delta_crdt/lib/delta_crdt/causal_crdt.ex"))

# Patch delta_crdt reverse_diff to pattern-match the struct (Elixir 1.19 warnings).
patch_file(
    rel("deps/delta_crdt/lib/delta_crdt/causal_crdt.ex"),
    [
        ("  defp reverse_diff(diff) do\n", "  defp reverse_diff(%Diff{} = diff) do\n"),
    ],
)

# Patch grpc struct updates for Elixir 1.19 typing warnings.
patch_file(
    rel("deps/grpc/lib/grpc/protoc/generator.ex"),
    [
        (
            "  defp generate_module_definitions(ctx, %Google.Protobuf.FileDescriptorProto{} = desc) do\n",
            "  defp generate_module_definitions(%Context{} = ctx, %Google.Protobuf.FileDescriptorProto{} = desc) do\n",
        ),
    ],
)
patch_file(
    rel("deps/grpc/lib/grpc/protoc/cli.ex"),
    [
        (
            '  defp parse_param("plugins=" <> plugins, ctx) do\n',
            '  defp parse_param("plugins=" <> plugins, %Context{} = ctx) do\n',
        ),
        (
            '  defp parse_param("gen_descriptors=" <> value, ctx) do\n',
            '  defp parse_param("gen_descriptors=" <> value, %Context{} = ctx) do\n',
        ),
        (
            '  defp parse_param("package_prefix=" <> package, ctx) do\n',
            '  defp parse_param("package_prefix=" <> package, %Context{} = ctx) do\n',
        ),
        (
            '  defp parse_param("transform_module=" <> module, ctx) do\n',
            '  defp parse_param("transform_module=" <> module, %Context{} = ctx) do\n',
        ),
        (
            '  defp parse_param("one_file_per_module=" <> value, ctx) do\n',
            '  defp parse_param("one_file_per_module=" <> value, %Context{} = ctx) do\n',
        ),
    ],
)
patch_file(
    rel("deps/grpc/lib/grpc/client/connection.ex"),
    [
        (
            "  defp build_balanced_state(base_state, addresses, config, lb_policy_opt, norm_opts, adapter) do\n",
            "  defp build_balanced_state(%__MODULE__{} = base_state, addresses, config, lb_policy_opt, norm_opts, adapter) do\n",
        ),
        (
            "  defp build_direct_state(base_state, norm_target, norm_opts, adapter) do\n",
            "  defp build_direct_state(%__MODULE__{} = base_state, norm_target, norm_opts, adapter) do\n",
        ),
        (
            "  defp build_real_channels(addresses, virtual_channel, norm_opts, adapter) do\n",
            "  defp build_real_channels(addresses, %Channel{} = virtual_channel, norm_opts, adapter) do\n",
        ),
        (
            "  defp connect_real_channel(vc, host, port, opts, adapter) do\n",
            "  defp connect_real_channel(%Channel{} = vc, host, port, opts, adapter) do\n",
        ),
    ],
)

# Patch OpenApiSpex cast helpers for Elixir 1.19 typing warnings.
patch_file(
    rel("deps/open_api_spex/lib/open_api_spex/cast/all_of.ex"),
    [
        (
            "  defp cast_all_of(%{schema: %{allOf: [%Schema{} = schema | remaining]}} = ctx, acc) do\n",
            "  defp cast_all_of(%Cast{schema: %{allOf: [%Schema{} = schema | remaining]}} = ctx, acc) do\n",
        ),
        (
            "  defp cast_all_of(%{schema: %{allOf: [nested_schema | remaining]} = schema} = ctx, result) do\n",
            "  defp cast_all_of(%Cast{schema: %{allOf: [nested_schema | remaining]} = schema} = ctx, result) do\n",
        ),
    ],
)
patch_file(
    rel("deps/open_api_spex/lib/open_api_spex/cast/one_of.ex"),
    [
        (
            "  def cast(%_{schema: %{type: _, oneOf: []}} = ctx) do\n",
            "  def cast(%Cast{schema: %{type: _, oneOf: []}} = ctx) do\n",
        ),
        (
            "  def cast(%{schema: %{type: _, oneOf: schemas}} = ctx) do\n",
            "  def cast(%Cast{schema: %{type: _, oneOf: schemas}} = ctx) do\n",
        ),
        (
            "    castable_schemas =\n"
            "      Enum.reduce(schemas, {ctx, [], []}, fn schema, {ctx, results, error_schemas} ->\n",
            "    castable_schemas =\n"
            "      Enum.reduce(schemas, {ctx, [], []}, fn schema, {%Cast{} = ctx, results, error_schemas} ->\n",
        ),
    ],
)

patch_file(
    rel("deps/open_api_spex/lib/open_api_spex/cast/any_of.ex"),
    [
        (
            "  defp cast_any_of(%_{schema: %{anyOf: []}} = ctx, failed_schemas, :__not_casted) do\n",
            "  defp cast_any_of(%Cast{schema: %{anyOf: []}} = ctx, failed_schemas, :__not_casted) do\n",
        ),
        (
            "  defp cast_any_of(\n"
            "         %{schema: %{anyOf: [%Schema{} = schema | remaining]}} = ctx,\n",
            "  defp cast_any_of(\n"
            "         %Cast{schema: %{anyOf: [%Schema{} = schema | remaining]}} = ctx,\n",
        ),
        (
            "    new_ctx = put_in(ctx.schema.anyOf, remaining)\n",
            "    new_ctx = %Cast{} = put_in(ctx.schema.anyOf, remaining)\n",
        ),
        (
            "  defp cast_any_of(\n"
            "         %{schema: %{anyOf: [nested_schema | remaining]} = schema} = ctx,\n",
            "  defp cast_any_of(\n"
            "         %Cast{schema: %{anyOf: [nested_schema | remaining]} = schema} = ctx,\n",
        ),
        (
            '  defp cast_any_of(%_{schema: %{anyOf: [], "x-struct": module}} = ctx, _failed_schemas, acc)\n',
            '  defp cast_any_of(%Cast{schema: %{anyOf: [], "x-struct": module}} = ctx, _failed_schemas, acc)\n',
        ),
        (
            "  defp cast_any_of(%_{schema: %{anyOf: []}} = ctx, _failed_schemas, acc) do\n",
            "  defp cast_any_of(%Cast{schema: %{anyOf: []}} = ctx, _failed_schemas, acc) do\n",
        ),
    ],
)

patch_file(
    rel("deps/jetstream/lib/jetstream/api/object.ex"),
    [
        (
            "    with {:ok, meta} <- info(conn, bucket_name, object_name),\n",
            "    with {:ok, %Meta{} = meta} <- info(conn, bucket_name, object_name),\n",
        ),
    ],
)

patch_file(
    rel("deps/ash_state_machine/lib/ash_state_machine.ex"),
    [
        (
            "    defstruct [:action, :from, :to, :__identifier__]\n",
            "    defstruct [:action, :from, :to, :__identifier__, __spark_metadata__: nil]\n",
        ),
    ],
)

patch_file(
    rel("deps/ash_postgres/lib/resource_generator/spec.ex"),
    [
        (
            "defmodule AshPostgres.ResourceGenerator.Spec do\n",
            "defmodule AshPostgres.ResourceGenerator.Spec do\n"
            "  @compile {:no_warn_undefined, Igniter.Inflex}\n"
            "  @compile {:no_warn_undefined, Owl.IO}\n",
        ),
    ],
)

patch_file(
    rel("deps/broadway_dashboard/lib/broadway_dashboard.ex"),
    [
        (
            "            {:ok, push_redirect(socket, to: to)}\n",
            "            {:ok, push_navigate(socket, to: to)}\n",
        ),
    ],
)

patch_file(
    rel("deps/ash_json_api/lib/ash_json_api/plug/parser.ex"),
    [
        (
            "         {:ok, data, acc, conn},\n",
            "         {:ok, data, acc, %Plug.Conn{} = conn},\n",
        ),
    ],
)

patch_file(
    rel("deps/sweet_xml/lib/sweet_xml.ex"),
    [
        (
            "  def add_namespace(xpath, prefix, uri) do\n",
            "  def add_namespace(%SweetXpath{} = xpath, prefix, uri) do\n",
        ),
    ],
)

patch_file(
    rel("deps/samly/lib/samly/sp_handler.ex"),
    [
        (
            "    with {:ok, assertion} <- Helper.decode_idp_auth_resp(sp, saml_encoding, saml_response),\n",
            "    with {:ok, %Assertion{} = assertion} <- Helper.decode_idp_auth_resp(sp, saml_encoding, saml_response),\n",
        ),
    ],
)

patch_file(
    rel("deps/samly/lib/samly/idp_data.ex"),
    [
        (
            "  defp save_idp_config(idp_data, %{id: id, sp_id: sp_id} = opts_map)\n",
            "  defp save_idp_config(%IdpData{} = idp_data, %{id: id, sp_id: sp_id} = opts_map)\n",
        ),
        (
            "  defp update_esaml_recs(idp_data, service_providers, opts_map) do\n",
            "  defp update_esaml_recs(%IdpData{} = idp_data, service_providers, opts_map) do\n",
        ),
        (
            "  defp from_xml(metadata_xml, idp_data) when is_binary(metadata_xml) do\n",
            "  defp from_xml(metadata_xml, %IdpData{} = idp_data) when is_binary(metadata_xml) do\n",
        ),
    ],
)
