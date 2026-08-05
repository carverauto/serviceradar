"""This module contains the Gazelle runtime dependencies for the Erlang extension.
"""

GAZELLE_ERLANG_RUNTIME_DEPS = [
    "@rules_erlang//gazelle:dot_app_to_json",
    "@rules_erlang//gazelle/erl_attrs_to_json:erl_attrs_to_json",
    "@rules_erlang//gazelle:hex_metadata_config_to_json",
    "@rules_erlang//gazelle:rebar_config_to_json",
]
