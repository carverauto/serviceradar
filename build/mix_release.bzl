"""Lightweight rule to run `mix release` hermetically using rules_elixir toolchains."""

def _mix_release_impl(ctx):
    toolchain = ctx.toolchains["@rules_elixir//:toolchain_type"]
    rust_toolchain = ctx.toolchains["@rules_rust//rust:toolchain"]

    otp = toolchain.otpinfo
    elixir = toolchain.elixirinfo
    cargo = rust_toolchain.cargo
    rustc = rust_toolchain.rustc
    bun = ctx.file.bun

    erlang_home = otp.erlang_home
    otp_tar = getattr(otp, "release_dir_tar", None)
    # Use short_path for tree artifacts so the symlink forest in the sandbox
    # can find the binaries reliably.
    elixir_home = elixir.elixir_home or elixir.release_dir.short_path

    tar_out = ctx.outputs.out

    toolchain_inputs = [
        otp.version_file,
        elixir.version_file,
        cargo,
        rustc,
    ]
    if getattr(otp, "release_dir_tar", None):
        toolchain_inputs.append(otp.release_dir_tar)
    if getattr(elixir, "release_dir", None):
        toolchain_inputs.append(elixir.release_dir)

    transitive_inputs = []
    if getattr(rust_toolchain, "rustc_lib", None):
        # rustc depends on its own shared libraries (e.g. librustc_driver); make
        # sure they are available to the action sandbox, especially on remote
        # executors where runfiles are not automatically present.
        transitive_inputs.append(rust_toolchain.rustc_lib)
    if getattr(rust_toolchain, "rust_std", None):
        # Provide the Rust stdlib for the host/exec toolchain so cargo can find
        # the core/std crates when compiling NIFs on remote Linux builders.
        transitive_inputs.append(rust_toolchain.rust_std)

    hex_cache = ctx.file.hex_cache
    direct_inputs = toolchain_inputs + ctx.files.srcs + ctx.files.data + ctx.files.extra_dir_srcs
    if hex_cache:
        direct_inputs.append(hex_cache)
    if bun:
        direct_inputs.append(bun)

    inputs = depset(
        direct = direct_inputs,
        transitive = transitive_inputs,
    )

    extra_copy_cmds = []
    for d in ctx.attr.extra_dirs:
        parent = d.rpartition("/")[0] or "."
        extra_copy_cmds.append(
            'mkdir -p "$WORKDIR/{parent}"\ncopy_dir "$EXECROOT/{dir}/" "$WORKDIR/{dir}/"\n'.format(
                dir = d,
                parent = parent,
            ),
        )

    run_assets = "true" if ctx.attr.run_assets else "false"
    patch_script = """python3 - <<'PY'
from pathlib import Path

def patch_file(path, replacements):
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
    Path("deps/elixir_uuid/lib/uuid.ex"),
    [
        ("  use Bitwise, only_operators: true\\n", ""),
        ("  import Bitwise\\n", ""),
    ],
)

# Patch opentelemetry_api_experimental charlist deprecations under Elixir 1.19.
patch_file(
    Path("deps/opentelemetry_api_experimental/mix.exs"),
    [
        (":file.consult('rebar.config')", ":file.consult(~c\"rebar.config\")"),
        (
            ":file.consult('src/opentelemetry_api_experimental.app.src')",
            ":file.consult(~c\"src/opentelemetry_api_experimental.app.src\")",
        ),
    ],
)

# Patch protobuf to avoid struct-update typing warnings under Elixir 1.19.
patch_file(
    Path("deps/protobuf/lib/protobuf/dsl.ex"),
    [
        (
            "  defp cal_packed(props, _syntax), do: %FieldProps{props | packed?: false}\\n",
            "  defp cal_packed(%FieldProps{} = props, _syntax), do: %FieldProps{props | packed?: false}\\n",
        ),
        (
            "    Enum.reduce(opts, props, fn\\n"
            "      {:optional, optional?}, acc ->\\n"
            "        %FieldProps{acc | optional?: optional?}\\n\\n"
            "      {:proto3_optional, proto3_optional?}, acc ->\\n"
            "        %FieldProps{acc | proto3_optional?: proto3_optional?}\\n\\n"
            "      {:required, required?}, acc ->\\n"
            "        %FieldProps{acc | required?: required?}\\n\\n"
            "      {:enum, enum?}, acc ->\\n"
            "        %FieldProps{acc | enum?: enum?}\\n\\n"
            "      {:map, map?}, acc ->\\n"
            "        %FieldProps{acc | map?: map?}\\n\\n"
            "      {:repeated, repeated?}, acc ->\\n"
            "        %FieldProps{acc | repeated?: repeated?}\\n\\n"
            "      {:embedded, embedded}, acc ->\\n"
            "        %FieldProps{acc | embedded?: embedded}\\n\\n"
            "      {:deprecated, deprecated?}, acc ->\\n"
            "        %FieldProps{acc | deprecated?: deprecated?}\\n\\n"
            "      {:packed, packed?}, acc ->\\n"
            "        %FieldProps{acc | packed?: packed?}\\n\\n"
            "      {:type, type}, acc ->\\n"
            "        %FieldProps{acc | type: type}\\n\\n"
            "      {:default, default}, acc ->\\n"
            "        %FieldProps{acc | default: default}\\n\\n"
            "      {:oneof, oneof}, acc ->\\n"
            "        %FieldProps{acc | oneof: oneof}\\n\\n"
            "      {:json_name, json_name}, acc ->\\n"
            "        %FieldProps{acc | json_name: json_name}\\n"
            "    end)\\n",
            "    Enum.reduce(opts, props, fn\\n"
            "      {:optional, optional?}, %FieldProps{} = acc ->\\n"
            "        %FieldProps{acc | optional?: optional?}\\n\\n"
            "      {:proto3_optional, proto3_optional?}, %FieldProps{} = acc ->\\n"
            "        %FieldProps{acc | proto3_optional?: proto3_optional?}\\n\\n"
            "      {:required, required?}, %FieldProps{} = acc ->\\n"
            "        %FieldProps{acc | required?: required?}\\n\\n"
            "      {:enum, enum?}, %FieldProps{} = acc ->\\n"
            "        %FieldProps{acc | enum?: enum?}\\n\\n"
            "      {:map, map?}, %FieldProps{} = acc ->\\n"
            "        %FieldProps{acc | map?: map?}\\n\\n"
            "      {:repeated, repeated?}, %FieldProps{} = acc ->\\n"
            "        %FieldProps{acc | repeated?: repeated?}\\n\\n"
            "      {:embedded, embedded}, %FieldProps{} = acc ->\\n"
            "        %FieldProps{acc | embedded?: embedded}\\n\\n"
            "      {:deprecated, deprecated?}, %FieldProps{} = acc ->\\n"
            "        %FieldProps{acc | deprecated?: deprecated?}\\n\\n"
            "      {:packed, packed?}, %FieldProps{} = acc ->\\n"
            "        %FieldProps{acc | packed?: packed?}\\n\\n"
            "      {:type, type}, %FieldProps{} = acc ->\\n"
            "        %FieldProps{acc | type: type}\\n\\n"
            "      {:default, default}, %FieldProps{} = acc ->\\n"
            "        %FieldProps{acc | default: default}\\n\\n"
            "      {:oneof, oneof}, %FieldProps{} = acc ->\\n"
            "        %FieldProps{acc | oneof: oneof}\\n\\n"
            "      {:json_name, json_name}, %FieldProps{} = acc ->\\n"
            "        %FieldProps{acc | json_name: json_name}\\n"
            "    end)\\n",
        ),
    ],
)
patch_file(
    Path("deps/protobuf/lib/protobuf/protoc/generator.ex"),
    [
        (
            "  defp generate_module_definitions(ctx, %Google.Protobuf.FileDescriptorProto{} = desc) do\\n",
            "  defp generate_module_definitions(%Context{} = ctx, %Google.Protobuf.FileDescriptorProto{} = desc) do\\n",
        ),
    ],
)

# Patch protobuf cli.ex for parse_param functions
patch_file(
    Path("deps/protobuf/lib/protobuf/protoc/cli.ex"),
    [
        ('defp parse_param("plugins=" <> plugins, ctx) do\\n', 'defp parse_param("plugins=" <> plugins, %Context{} = ctx) do\\n'),
        ('defp parse_param("gen_descriptors=" <> value, ctx) do\\n', 'defp parse_param("gen_descriptors=" <> value, %Context{} = ctx) do\\n'),
        ('defp parse_param("package_prefix=" <> package, ctx) do\\n', 'defp parse_param("package_prefix=" <> package, %Context{} = ctx) do\\n'),
        ('defp parse_param("transform_module=" <> module, ctx) do\\n', 'defp parse_param("transform_module=" <> module, %Context{} = ctx) do\\n'),
        ('defp parse_param("one_file_per_module=" <> value, ctx) do\\n', 'defp parse_param("one_file_per_module=" <> value, %Context{} = ctx) do\\n'),
        ('defp parse_param("include_docs=" <> value, ctx) do\\n', 'defp parse_param("include_docs=" <> value, %Context{} = ctx) do\\n'),
    ],
)

# Patch protobuf message.ex for Context struct updates
patch_file(
    Path("deps/protobuf/lib/protobuf/protoc/generator/message.ex"),
    [
        ("  defp gen_nested_msgs(ctx, desc) do\\n", "  defp gen_nested_msgs(%Context{} = ctx, desc) do\\n"),
        ("  defp gen_nested_enums(ctx, desc) do\\n", "  defp gen_nested_enums(%Context{} = ctx, desc) do\\n"),
        ("  defp get_fields(ctx, desc) do\\n", "  defp get_fields(%Context{} = ctx, desc) do\\n"),
        ("  defp get_field(ctx, %FieldDescriptorProto{} = field_desc, nested_maps, oneofs) do\\n", "  defp get_field(%Context{} = ctx, %FieldDescriptorProto{} = field_desc, nested_maps, oneofs) do\\n"),
        ("  defp field_type_name(ctx, %FieldDescriptorProto{type_name: type_name} = field_desc) do\\n", "  defp field_type_name(%Context{} = ctx, %FieldDescriptorProto{type_name: type_name} = field_desc) do\\n"),
        ("  defp nested_maps(ctx, desc) do\\n", "  defp nested_maps(%Context{} = ctx, desc) do\\n"),
    ],
)

# Patch permit to avoid struct-update typing warnings under Elixir 1.19.
patch_file(
    Path("deps/permit/lib/permit/permissions/disjunctive_normal_form.ex"),
    [
        ("def add_clauses(dnf, clauses) do\\n", "def add_clauses(%DNF{} = dnf, clauses) do\\n"),
        ("def add_clauses(dnf, clause) do\\n", "def add_clauses(%DNF{} = dnf, clause) do\\n"),
    ],
)

# Patch protobuf extension.ex for Context struct updates
patch_file(
    Path("deps/protobuf/lib/protobuf/protoc/generator/extension.ex"),
    [
        ("  defp generate_extend_dsl(ctx, %FieldDescriptorProto{} = f, ns) do\\n", "  defp generate_extend_dsl(%Context{} = ctx, %FieldDescriptorProto{} = f, ns) do\\n"),
        # Convert the complex struct update to use map update syntax instead
        # The function already has %Context{} = ctx pattern match, so we can use %{} for the update
        (
            "          %Context{\\n"
            "            Context.append_comment_path(ctx, \\"6.#{index}\\")\\n"
            "            | namespace: ctx.namespace ++ [Macro.camelize(desc.name)]\\n"
            "          },",
            "          (fn %Context{} = c -> %Context{c | namespace: ctx.namespace ++ [Macro.camelize(desc.name)]} end).(Context.append_comment_path(ctx, \\"6.#{index}\\")),",
        ),
    ],
)

# Patch protobuf service.ex for Context struct updates
patch_file(
    Path("deps/protobuf/lib/protobuf/protoc/generator/service.ex"),
    [
        ("  defp generate_service_method(ctx, method) do\\n", "  defp generate_service_method(%Context{} = ctx, method) do\\n"),
    ],
)

# Patch additional dsl.ex function
patch_file(
    Path("deps/protobuf/lib/protobuf/dsl.ex"),
    [
        ("  defp cal_json_name(props), do: %FieldProps{props | json_name: props.name}\\n", "  defp cal_json_name(%FieldProps{} = props), do: %FieldProps{props | json_name: props.name}\\n"),
    ],
)

# Patch delta_crdt warnings/errors under Elixir 1.19.
patch_file(
    Path("deps/delta_crdt/lib/delta_crdt.ex"),
    [
        ("Logger.warn(", "Logger.warning("),
    ],
)
patch_file(
    Path("deps/delta_crdt/lib/delta_crdt/aw_lww_map.ex"),
    [
        ("Logger.warn(", "Logger.warning("),
    ],
)
def patch_delta_crdt_causal(path):
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
            "diff = case diff do\\n"
            "      %DeltaCrdt.CausalCrdt.Diff{} = diff -> diff\\n"
            "      _ -> diff\\n"
            "    end\\n"
            "    %DeltaCrdt.CausalCrdt.Diff{diff | continuation: truncate(continuation, state.max_sync_size)}"
        )
        text = text.replace(target_fq, replacement_fq)
    target_alias = "%Diff{diff | continuation: truncate(continuation, state.max_sync_size)}"
    if target_alias in text:
        replacement_alias = (
            "diff = case diff do\\n"
            "      %Diff{} = diff -> diff\\n"
            "      _ -> diff\\n"
            "    end\\n"
            "    %Diff{diff | continuation: truncate(continuation, state.max_sync_size)}"
        )
        text = text.replace(target_alias, replacement_alias)
    if text != original:
        path.write_text(text)

patch_delta_crdt_causal(Path("deps/delta_crdt/lib/delta_crdt/causal_crdt.ex"))

# Patch delta_crdt reverse_diff to pattern-match the struct (Elixir 1.19 warnings).
patch_file(
    Path("deps/delta_crdt/lib/delta_crdt/causal_crdt.ex"),
    [
        ("  defp reverse_diff(diff) do\\n", "  defp reverse_diff(%Diff{} = diff) do\\n"),
    ],
)

# Patch grpc struct updates for Elixir 1.19 typing warnings.
patch_file(
    Path("deps/grpc/lib/grpc/protoc/generator.ex"),
    [
        (
            "  defp generate_module_definitions(ctx, %Google.Protobuf.FileDescriptorProto{} = desc) do\\n",
            "  defp generate_module_definitions(%Context{} = ctx, %Google.Protobuf.FileDescriptorProto{} = desc) do\\n",
        ),
    ],
)
patch_file(
    Path("deps/grpc/lib/grpc/protoc/cli.ex"),
    [
        ('  defp parse_param("plugins=" <> plugins, ctx) do\\n', '  defp parse_param("plugins=" <> plugins, %Context{} = ctx) do\\n'),
        ('  defp parse_param("gen_descriptors=" <> value, ctx) do\\n', '  defp parse_param("gen_descriptors=" <> value, %Context{} = ctx) do\\n'),
        ('  defp parse_param("package_prefix=" <> package, ctx) do\\n', '  defp parse_param("package_prefix=" <> package, %Context{} = ctx) do\\n'),
        ('  defp parse_param("transform_module=" <> module, ctx) do\\n', '  defp parse_param("transform_module=" <> module, %Context{} = ctx) do\\n'),
        ('  defp parse_param("one_file_per_module=" <> value, ctx) do\\n', '  defp parse_param("one_file_per_module=" <> value, %Context{} = ctx) do\\n'),
    ],
)
patch_file(
    Path("deps/grpc/lib/grpc/client/connection.ex"),
    [
        (
            "  defp build_balanced_state(base_state, addresses, config, lb_policy_opt, norm_opts, adapter) do\\n",
            "  defp build_balanced_state(%__MODULE__{} = base_state, addresses, config, lb_policy_opt, norm_opts, adapter) do\\n",
        ),
        (
            "  defp build_direct_state(base_state, norm_target, norm_opts, adapter) do\\n",
            "  defp build_direct_state(%__MODULE__{} = base_state, norm_target, norm_opts, adapter) do\\n",
        ),
        (
            "  defp build_real_channels(addresses, virtual_channel, norm_opts, adapter) do\\n",
            "  defp build_real_channels(addresses, %Channel{} = virtual_channel, norm_opts, adapter) do\\n",
        ),
        (
            "  defp connect_real_channel(vc, host, port, opts, adapter) do\\n",
            "  defp connect_real_channel(%Channel{} = vc, host, port, opts, adapter) do\\n",
        ),
    ],
)

# Patch OpenApiSpex cast helpers for Elixir 1.19 typing warnings.
patch_file(
    Path("deps/open_api_spex/lib/open_api_spex/cast/all_of.ex"),
    [
        (
            "  defp cast_all_of(%{schema: %{allOf: [%Schema{} = schema | remaining]}} = ctx, acc) do\\n",
            "  defp cast_all_of(%Cast{schema: %{allOf: [%Schema{} = schema | remaining]}} = ctx, acc) do\\n",
        ),
        (
            "  defp cast_all_of(%{schema: %{allOf: [nested_schema | remaining]} = schema} = ctx, result) do\\n",
            "  defp cast_all_of(%Cast{schema: %{allOf: [nested_schema | remaining]} = schema} = ctx, result) do\\n",
        ),
    ],
)
patch_file(
    Path("deps/open_api_spex/lib/open_api_spex/cast/one_of.ex"),
    [
        (
            "  def cast(%_{schema: %{type: _, oneOf: []}} = ctx) do\\n",
            "  def cast(%Cast{schema: %{type: _, oneOf: []}} = ctx) do\\n",
        ),
        (
            "  def cast(%{schema: %{type: _, oneOf: schemas}} = ctx) do\\n",
            "  def cast(%Cast{schema: %{type: _, oneOf: schemas}} = ctx) do\\n",
        ),
        (
            "    castable_schemas =\\n"
            "      Enum.reduce(schemas, {ctx, [], []}, fn schema, {ctx, results, error_schemas} ->\\n",
            "    castable_schemas =\\n"
            "      Enum.reduce(schemas, {ctx, [], []}, fn schema, {%Cast{} = ctx, results, error_schemas} ->\\n",
        ),
    ],
)

patch_file(
    Path("deps/open_api_spex/lib/open_api_spex/cast/any_of.ex"),
    [
        (
            "  defp cast_any_of(%_{schema: %{anyOf: []}} = ctx, failed_schemas, :__not_casted) do\\n",
            "  defp cast_any_of(%Cast{schema: %{anyOf: []}} = ctx, failed_schemas, :__not_casted) do\\n",
        ),
        (
            "  defp cast_any_of(\\n"
            "         %{schema: %{anyOf: [%Schema{} = schema | remaining]}} = ctx,\\n",
            "  defp cast_any_of(\\n"
            "         %Cast{schema: %{anyOf: [%Schema{} = schema | remaining]}} = ctx,\\n",
        ),
        (
            "    new_ctx = put_in(ctx.schema.anyOf, remaining)\\n",
            "    new_ctx = %Cast{} = put_in(ctx.schema.anyOf, remaining)\\n",
        ),
        (
            "  defp cast_any_of(\\n"
            "         %{schema: %{anyOf: [nested_schema | remaining]} = schema} = ctx,\\n",
            "  defp cast_any_of(\\n"
            "         %Cast{schema: %{anyOf: [nested_schema | remaining]} = schema} = ctx,\\n",
        ),
        (
            '  defp cast_any_of(%_{schema: %{anyOf: [], "x-struct": module}} = ctx, _failed_schemas, acc)\\n',
            '  defp cast_any_of(%Cast{schema: %{anyOf: [], "x-struct": module}} = ctx, _failed_schemas, acc)\\n',
        ),
        (
            "  defp cast_any_of(%_{schema: %{anyOf: []}} = ctx, _failed_schemas, acc) do\\n",
            "  defp cast_any_of(%Cast{schema: %{anyOf: []}} = ctx, _failed_schemas, acc) do\\n",
        ),
    ],
)

patch_file(
    Path("deps/jetstream/lib/jetstream/api/object.ex"),
    [
        (
            "    with {:ok, meta} <- info(conn, bucket_name, object_name),\\n",
            "    with {:ok, %Meta{} = meta} <- info(conn, bucket_name, object_name),\\n",
        ),
    ],
)

patch_file(
    Path("deps/ash_state_machine/lib/ash_state_machine.ex"),
    [
        (
            "    defstruct [:action, :from, :to, :__identifier__]\\n",
            "    defstruct [:action, :from, :to, :__identifier__, __spark_metadata__: nil]\\n",
        ),
    ],
)

patch_file(
    Path("deps/ash_postgres/lib/resource_generator/spec.ex"),
    [
        (
            "defmodule AshPostgres.ResourceGenerator.Spec do\\n",
            "defmodule AshPostgres.ResourceGenerator.Spec do\\n"
            "  @compile {:no_warn_undefined, Igniter.Inflex}\\n"
            "  @compile {:no_warn_undefined, Owl.IO}\\n",
        ),
    ],
)

patch_file(
    Path("deps/broadway_dashboard/lib/broadway_dashboard.ex"),
    [
        (
            "            {:ok, push_redirect(socket, to: to)}\\n",
            "            {:ok, push_navigate(socket, to: to)}\\n",
        ),
    ],
)

patch_file(
    Path("deps/ash_json_api/lib/ash_json_api/plug/parser.ex"),
    [
        (
            "         {:ok, data, acc, conn},\\n",
            "         {:ok, data, acc, %Plug.Conn{} = conn},\\n",
        ),
    ],
)

patch_file(
    Path("deps/sweet_xml/lib/sweet_xml.ex"),
    [
        (
            "  def add_namespace(xpath, prefix, uri) do\\n",
            "  def add_namespace(%SweetXpath{} = xpath, prefix, uri) do\\n",
        ),
    ],
)

patch_file(
    Path("deps/samly/lib/samly/sp_handler.ex"),
    [
        (
            "    with {:ok, assertion} <- Helper.decode_idp_auth_resp(sp, saml_encoding, saml_response),\\n",
            "    with {:ok, %Assertion{} = assertion} <- Helper.decode_idp_auth_resp(sp, saml_encoding, saml_response),\\n",
        ),
    ],
)

patch_file(
    Path("deps/samly/lib/samly/idp_data.ex"),
    [
        (
            "  defp save_idp_config(idp_data, %{id: id, sp_id: sp_id} = opts_map)\\n",
            "  defp save_idp_config(%IdpData{} = idp_data, %{id: id, sp_id: sp_id} = opts_map)\\n",
        ),
        (
            "  defp update_esaml_recs(idp_data, service_providers, opts_map) do\\n",
            "  defp update_esaml_recs(%IdpData{} = idp_data, service_providers, opts_map) do\\n",
        ),
        (
            "  defp from_xml(metadata_xml, idp_data) when is_binary(metadata_xml) do\\n",
            "  defp from_xml(metadata_xml, %IdpData{} = idp_data) when is_binary(metadata_xml) do\\n",
        ),
    ],
)
PY
"""
    # Note: We use a placeholder and manual replacement instead of .format()
    # because .format() doesn't unescape {{ in substituted values.
    patch_script_placeholder = "___PATCH_SCRIPT_PLACEHOLDER___"

    ctx.actions.run_shell(
        mnemonic = "MixRelease",
        inputs = inputs,
        outputs = [tar_out],
        progress_message = "mix release ({})".format(ctx.label.name),
command = """
set -euo pipefail

EXECROOT=$PWD

ELIXIR_HOME_RAW="{elixir_home}"
ELIXIR_HOME=$(cd "$EXECROOT" && cd "$ELIXIR_HOME_RAW" && pwd)

if [ -n "{otp_tar}" ] && [ -f "{otp_tar}" ]; then
  OTP_ROOT=$(mktemp -d)
  tar -xf "{otp_tar}" -C "$OTP_ROOT"
  if [ -d "$OTP_ROOT/lib/erlang" ]; then
    ERLANG_HOME="$OTP_ROOT/lib/erlang"
  else
    ERLANG_HOME=$(find "$OTP_ROOT" -maxdepth 2 -type d -name erlang -print | head -n1 | xargs dirname)
  fi
else
  ERLANG_HOME="{erlang_home}"
fi
echo "OTP_TAR={otp_tar}"
echo "ERLANG_HOME=$ERLANG_HOME"

WORKDIR=$(mktemp -d)
export HOME="$WORKDIR/.mix_home"
export MIX_HOME="$HOME/.mix"
export HEX_HOME="$HOME/.hex"
export REBAR_BASE_DIR="$HOME/.cache/rebar3"
export MIX_ENV=prod
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export ELIXIR_ERL_OPTIONS="+fnu"
export CARGO="$EXECROOT/{cargo_path}"
export RUSTC="$EXECROOT/{rustc_path}"
export PATH="$(dirname "$CARGO"):$(dirname "$RUSTC"):/opt/homebrew/bin:$ELIXIR_HOME/bin:$ERLANG_HOME/bin:$PATH"
BUN_BIN="{bun_path}"
if [ -n "$BUN_BIN" ] && [ -f "$EXECROOT/$BUN_BIN" ]; then
  chmod +x "$EXECROOT/$BUN_BIN" || true
  export PATH="$(dirname "$EXECROOT/$BUN_BIN"):$PATH"
fi
RUST_LIB_ROOT="$(cd "$(dirname "$RUSTC")/.." && pwd)"
export LD_LIBRARY_PATH="$RUST_LIB_ROOT/lib:$RUST_LIB_ROOT/lib/rustlib/x86_64-unknown-linux-gnu/lib:${{LD_LIBRARY_PATH:-}}"
echo "PATH=$PATH"
ls -la "$ELIXIR_HOME/bin" || true
which mix || true

copy_dir() {{
  local src="$1"
  local dest="$2"
  if command -v rsync >/dev/null 2>&1; then
    # Bazel presents source files as symlinks in execroot; dereference them
    # so Mix writes (e.g. mix.lock updates) stay inside the writable WORKDIR.
    rsync -aL "$src" "$dest"
  else
    mkdir -p "$dest"
    cp -aL "${{src%/}}/." "$dest"
  fi
}}

if [ ! -x "$ERLANG_HOME/bin/erl" ]; then
  echo "Erlang not found under $ERLANG_HOME"
  ls -la "$ERLANG_HOME" || true
fi

mkdir -p "$HOME"
export CARGO_TARGET_DIR="$WORKDIR/_cargo_target"
TMPROOT="$WORKDIR/_tmp"
SYS_TMP=$(python3 - <<'PY'
import tempfile
print(tempfile.gettempdir())
PY
)
mkdir -p "$TMPROOT"
export TMPDIR="$TMPROOT"
export RUSTLER_TMPDIR="$TMPROOT"
export RUSTLER_TEMP_DIR="$TMPROOT"
if [ -n "{hex_cache_tar}" ] && [ -f "$EXECROOT/{hex_cache_tar}" ]; then
  case "$EXECROOT/{hex_cache_tar}" in
    *.tar.gz|*.tgz) tar -xzf "$EXECROOT/{hex_cache_tar}" -C "$HOME" ;;
    *) tar -xf "$EXECROOT/{hex_cache_tar}" -C "$HOME" ;;
  esac
  # NOTE: We intentionally do NOT set HEX_OFFLINE=1 here.
  # The hex_cache is an optimization to pre-seed packages, but if any
  # packages are missing or outdated, Mix should be allowed to fetch them.
  # This avoids the need to manually regenerate hex_cache.tar.gz every time
  # dependencies change.
fi
if [ -d /cache ] && [ -w /cache ]; then
  export CARGO_HOME="/cache/cargo"
else
  export CARGO_HOME="$HOME/.cargo"
fi
mkdir -p "$CARGO_HOME"
copy_dir "{src_dir}/" "$WORKDIR/"
{extra_copy}
if [ -f "$EXECROOT/Cargo.toml" ]; then
  cp "$EXECROOT/Cargo.toml" "$WORKDIR/Cargo.toml"
  [ -f "$EXECROOT/Cargo.lock" ] && cp "$EXECROOT/Cargo.lock" "$WORKDIR/Cargo.lock"

  if [ -d "$EXECROOT/rust/srql" ]; then
    mkdir -p "$WORKDIR/rust/srql"
    copy_dir "$EXECROOT/rust/srql/" "$WORKDIR/rust/srql/"
  fi
  if [ -d "$EXECROOT/rust/kvutil" ]; then
    mkdir -p "$WORKDIR/rust/kvutil"
    copy_dir "$EXECROOT/rust/kvutil/" "$WORKDIR/rust/kvutil/"
  fi
  if [ -d "$EXECROOT/proto" ]; then
    mkdir -p "$TMPROOT/rust/kvutil/proto"
    copy_dir "$EXECROOT/proto/" "$TMPROOT/rust/kvutil/proto/"
    mkdir -p "$SYS_TMP/rust/kvutil/proto"
    copy_dir "$EXECROOT/proto/" "$SYS_TMP/rust/kvutil/proto/"
  fi

  if [ -d "$WORKDIR/rust" ]; then
    mkdir -p /tmp/rust
    rm -rf /tmp/rust/srql /tmp/rust/kvutil
    [ -d "$WORKDIR/rust/srql" ] && ln -s "$WORKDIR/rust/srql" /tmp/rust/srql
    [ -d "$WORKDIR/rust/kvutil" ] && ln -s "$WORKDIR/rust/kvutil" /tmp/rust/kvutil
    cat > /tmp/rust/Cargo.toml <<'EOF'
[workspace]
resolver = "2"
members = ["srql", "kvutil"]

[workspace.dependencies]
tonic = {{ version = "0.12", features = ["tls"] }}
prost = "0.13"
tonic-build = "0.12"
tokio = {{ version = "1" }}
tokio-stream = "0.1"
tonic-health = "0.12"
tonic-reflection = "0.12"

[profile.release]
opt-level = 3
debug = false
rpath = false
lto = true
debug-assertions = false
panic = "abort"
EOF
  fi
fi

mkdir -p /tmp/elixir
rm -rf /tmp/elixir/datasvc
ln -s "$WORKDIR/elixir/datasvc" /tmp/elixir/datasvc
rm -rf /tmp/elixir/serviceradar_core
ln -s "$WORKDIR/elixir/serviceradar_core" /tmp/elixir/serviceradar_core
rm -rf /tmp/elixir/serviceradar_srql
ln -s "$WORKDIR/elixir/serviceradar_srql" /tmp/elixir/serviceradar_srql
rm -rf /tmp/serviceradar_core
ln -s "$WORKDIR/elixir/serviceradar_core" /tmp/serviceradar_core
rm -rf /tmp/serviceradar_srql
ln -s "$WORKDIR/elixir/serviceradar_srql" /tmp/serviceradar_srql
rm -rf /tmp/datasvc
ln -s "$WORKDIR/elixir/datasvc" /tmp/datasvc

cd "$WORKDIR"
chmod -R u+w .

# Fetch and compile deps, build assets, create release into Bazel output dir
if ! ls "$MIX_HOME/archives/hex-"* >/dev/null 2>&1; then
  mix local.hex --force
fi
if [ -x "$MIX_HOME/rebar3" ]; then
  export MIX_REBAR3="$MIX_HOME/rebar3"
elif ls "$MIX_HOME/elixir"/*/rebar3 >/dev/null 2>&1; then
  export MIX_REBAR3=$(ls "$MIX_HOME/elixir"/*/rebar3 | head -n 1)
fi
if [ -z "${{MIX_REBAR3:-}}" ]; then
  mix local.rebar --force
fi
mix deps.get --only prod
{patch_script}
mix deps.compile
if [ "{run_assets}" = "true" ]; then
  # Preserve existing static assets (favicon, images, robots.txt) before clearing priv/static
  PRESERVED_STATIC=$(mktemp -d)
  if [ -d priv/static ]; then
    [ -f priv/static/favicon.ico ] && cp priv/static/favicon.ico "$PRESERVED_STATIC/"
    [ -f priv/static/robots.txt ] && cp priv/static/robots.txt "$PRESERVED_STATIC/"
    [ -d priv/static/images ] && cp -r priv/static/images "$PRESERVED_STATIC/"
  fi

  STATIC_ROOT="$WORKDIR/priv_static"
  DIGEST_ROOT="$WORKDIR/priv_static_digest"
  rm -rf priv/static "$DIGEST_ROOT"
  mkdir -p "$STATIC_ROOT/assets/css"
  ln -s "$STATIC_ROOT" priv/static
  : > priv/static/assets/css/app.css

  # Restore preserved static assets to the symlinked directory
  [ -f "$PRESERVED_STATIC/favicon.ico" ] && cp "$PRESERVED_STATIC/favicon.ico" priv/static/
  [ -f "$PRESERVED_STATIC/robots.txt" ] && cp "$PRESERVED_STATIC/robots.txt" priv/static/
  [ -d "$PRESERVED_STATIC/images" ] && cp -r "$PRESERVED_STATIC/images" priv/static/

  # Install npm dependencies for React components
  if ! command -v bun >/dev/null 2>&1; then
    echo "bun is required for assets but was not found on PATH" >&2
    exit 1
  fi
  if [ -f assets/package.json ]; then
    if [ -f assets/bun.lockb ] || [ -f assets/bun.lock ]; then
      (cd assets && bun install --frozen-lockfile)
    else
      (cd assets && bun install)
    fi
  fi
  if [ -f assets/component/package.json ]; then
    if [ -f assets/component/bun.lockb ] || [ -f assets/component/bun.lock ]; then
      (cd assets/component && bun install --frozen-lockfile)
    else
      (cd assets/component && bun install)
    fi
  fi

  TAILWIND_INPUT=assets/css/app.css \
  TAILWIND_OUTPUT=priv/static/assets/css/app.css \
  mix tailwind serviceradar_web_ng --minify
  mix esbuild serviceradar_web_ng --minify

  # Bundle React components for Phoenix React Server (if component directory exists)
  if [ -d assets/component/src ] && [ -f assets/component/package.json ]; then
    mkdir -p priv/react
    mix phx.react.bun.bundle --component-base=assets/component/src --output="$WORKDIR/priv/react/server.js" --cd="$WORKDIR/assets/component"
  fi

  mix phx.digest priv/static -o "$DIGEST_ROOT"
  rm priv/static
  mv "$DIGEST_ROOT" priv/static
fi
RELEASE_DIR=$(mktemp -d)
mix release --path "$RELEASE_DIR"

# Package release to tar output (ensure parent exists, write via absolute path)
mkdir -p "$(dirname "$EXECROOT/{tar_out}")"
tar -czf "$EXECROOT/{tar_out}" -C "$RELEASE_DIR" .
""".format(
            elixir_home = elixir_home,
            erlang_home = erlang_home,
            src_dir = ctx.attr.src_dir,
            tar_out = tar_out.path,
            cargo_path = cargo.path,
            rustc_path = rustc.path,
            cargo_dir = cargo.dirname,
            rustc_dir = rustc.dirname,
            otp_tar = otp_tar.path if otp_tar else "",
            extra_copy = "".join(extra_copy_cmds),
            run_assets = run_assets,
            patch_script = patch_script_placeholder,
            hex_cache_tar = hex_cache.path if hex_cache else "",
            bun_path = bun.path if bun else "",
        ).replace(patch_script_placeholder, patch_script),
        use_default_shell_env = False,
    )

    return [
        DefaultInfo(
            files = depset([tar_out]),
        ),
    ]

mix_release = rule(
    implementation = _mix_release_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True, doc = "Web-NG sources"),
        "data": attr.label_list(allow_files = True, doc = "Additional data files (e.g., priv/static)"),
        "src_dir": attr.string(default = "web-ng", doc = "Path to the web-ng project root relative to workspace"),
        "out": attr.output(mandatory = True),
        "run_assets": attr.bool(default = True, doc = "Whether to run assets.deploy steps"),
        "extra_dirs": attr.string_list(doc = "Workspace-relative directories to copy into the build workspace"),
        "extra_dir_srcs": attr.label_list(allow_files = True, doc = "File inputs that back extra_dirs"),
        "hex_cache": attr.label(allow_single_file = True, doc = "Tarball containing offline Hex/Mix cache"),
        "bun": attr.label(allow_single_file = True, doc = "Optional bun binary for SSR asset builds"),
    },
    toolchains = [
        "@rules_elixir//:toolchain_type",
        "@rules_rust//rust:toolchain",
    ],
)
