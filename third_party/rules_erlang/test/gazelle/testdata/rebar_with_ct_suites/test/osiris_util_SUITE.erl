%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(osiris_util_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-export([]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% Common Test callbacks
%%%===================================================================

all() ->
    [{group, tests}].

all_tests() ->
    [to_base64uri_test,
     inet_tls_enabled,
     replication_over_tls_configuration_with_optfile,
     replication_over_tls_configuration_with_opt].

groups() ->
    [{tests, [], all_tests()}].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%%===================================================================
%%% Test cases
%%%===================================================================

to_base64uri_test(_Config) ->
    ?assertEqual("Myqueue", osiris_util:to_base64uri("Myqueue")),
    ?assertEqual("my__queue", osiris_util:to_base64uri("my%*queue")),
    ?assertEqual("my99___queue",
                 osiris_util:to_base64uri("my99_[]queue")).

inet_tls_enabled(_) ->
    InitArgs = init:get_arguments(),
    ?assert(osiris_util:inet_tls_enabled(InitArgs
                                         ++ [{proto_dist, ["inet_tls"]}])),
    ?assertNot(osiris_util:inet_tls_enabled(InitArgs)),
    ok.

replication_over_tls_configuration_with_optfile(Config) ->
    ExpectedOkConfig =
        [{replication_transport, ssl},
         {replication_server_ssl_options,
          [{cacertfile, "/etc/rabbitmq/ca_certificate.pem"},
           {certfile, "/etc/rabbitmq/server_certificate.pem"},
           {keyfile, "/etc/rabbitmq/server_key.pem"},
           {secure_renegotiate, true},
           {verify, verify_peer},
           {fail_if_no_peer_cert, true}]},
         {replication_client_ssl_options,
          [{cacertfile, "/etc/rabbitmq/ca_certificate.pem"},
           {certfile, "/etc/rabbitmq/client_certificate.pem"},
           {keyfile, "/etc/rabbitmq/client_key.pem"},
           {secure_renegotiate, true},
           {verify, verify_peer},
           {fail_if_no_peer_cert, true}]}],
    [begin
         InitArgs =
             [{proto_dist, ["inet_tls"]},
              {ssl_dist_optfile, [?config(data_dir, Config) ++ File]}],
         ?assertEqual(ExpectedOkConfig,
                      replication_over_tls_configuration(InitArgs))
     end
     || File
            <- ["inter_node_tls_server_client_ok.config",
                "inter_node_tls_client_server_ok.config"]],

    FileBroken =
        ?config(data_dir, Config) ++ "inter_node_tls_broken.config",
    InitArgsBroken =
        [{proto_dist, ["inet_tls"]}, {ssl_dist_optfile, [FileBroken]}],
    ?assertEqual([], replication_over_tls_configuration(InitArgsBroken)),

    FileNotFound =
        ?config(data_dir, Config) ++ "inter_node_tls_not_found.config",
    InitArgsNotFound =
        [{proto_dist, ["inet_tls"]}, {ssl_dist_optfile, [FileNotFound]}],
    ?assertEqual([],
                 replication_over_tls_configuration(InitArgsNotFound)),

    ok.

replication_over_tls_configuration_with_opt(_) ->
    InitArgs =
        [{proto_dist, ["inet_tls"]},
         {ssl_dist_opt,
          ["server_cacertfile", "/etc/rabbitmq/ca_certificate.pem"]},
         {ssl_dist_opt,
          ["server_certfile", "/etc/rabbitmq/server_certificate.pem"]},
         {ssl_dist_opt, ["server_keyfile", "/etc/rabbitmq/server_key.pem"]},
         {ssl_dist_opt, ["server_verify", "verify_peer"]},
         {ssl_dist_opt, ["server_fail_if_no_peer_cert", "true"]},
         {ssl_dist_opt,
          ["client_cacertfile", "/etc/rabbitmq/ca_certificate.pem"]},
         {ssl_dist_opt,
          ["client_certfile", "/etc/rabbitmq/client_certificate.pem"]},
         {ssl_dist_opt, ["client_keyfile", "/etc/rabbitmq/client_key.pem"]},
         {ssl_dist_opt, ["client_verify", "verify_peer"]},
         {ssl_dist_opt,
          ["server_secure_renegotiate",
           "true",
           "client_secure_renegotiate",
           "true"]}],

    ?assertEqual([{replication_transport, ssl},
                  {replication_server_ssl_options,
                   [{cacertfile, "/etc/rabbitmq/ca_certificate.pem"},
                    {certfile, "/etc/rabbitmq/server_certificate.pem"},
                    {keyfile, "/etc/rabbitmq/server_key.pem"},
                    {verify, verify_peer},
                    {fail_if_no_peer_cert, true},
                    {secure_renegotiate, true}]},
                  {replication_client_ssl_options,
                   [{cacertfile, "/etc/rabbitmq/ca_certificate.pem"},
                    {certfile, "/etc/rabbitmq/client_certificate.pem"},
                    {keyfile, "/etc/rabbitmq/client_key.pem"},
                    {verify, verify_peer},
                    {secure_renegotiate, true}]}],
                 replication_over_tls_configuration(InitArgs)),

    ExtraInitArgs =
        [{proto_dist, ["inet_tls"]},
         {ssl_dist_opt,
          ["server_verify_fun",
           "{some_module,some_function,some_initial_state}"]},
         {ssl_dist_opt, ["server_crl_check", "true"]},
         {ssl_dist_opt,
          ["server_crl_cache", "{ssl_crl_cache, {internal, []}}"]},
         {ssl_dist_opt, ["server_reuse_sessions", "save"]},
         {ssl_dist_opt, ["server_depth", "1"]},
         {ssl_dist_opt, ["server_hibernate_after", "10"]},
         {ssl_dist_opt,
          ["server_ciphers", "TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256"]},
         {ssl_dist_opt, ["server_dhfile", "/some/file"]},
         {ssl_dist_opt, ["server_password", "bunnies"]}],

    ?assertEqual([{replication_transport, ssl},
                  {replication_server_ssl_options,
                   [{verify_fun,
                     {some_module, some_function, some_initial_state}},
                    {crl_check, true},
                    {crl_cache, {ssl_crl_cache, {internal, []}}},
                    {reuse_sessions, save},
                    {depth, 1},
                    {hibernate_after, 10},
                    {ciphers, "TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256"},
                    {dhfile, "/some/file"},
                    {password, "bunnies"}]},
                  {replication_client_ssl_options, []}],
                 replication_over_tls_configuration(ExtraInitArgs)),

    ok.

replication_over_tls_configuration(Args) ->
    osiris_util:replication_over_tls_configuration(Args,
                                                   fun file:consult/1,
                                                   fun tls_replication_log/3).

tls_replication_log(_Level, Fmt, Args) ->
    ct:log(Fmt, Args).
