PROJECT = seshat
PROJECT_DESCRIPTION = Metrics library built for RabbitMQ, with a Prometheus exposition format built-in
PROJECT_VERSION = 0.1.0

define PROJECT_ENV
[
]
endef

LOCAL_DEPS = sasl crypto

# TEST_DEPS=eunit_formatters looking_glass
TEST_DEPS=eunit_formatters

dep_looking_glass = git https://github.com/rabbitmq/looking-glass.git master
# PLT_APPS += eunit syntax_tools erts kernel stdlib common_test inets ssh ssl meck looking_glass gen_batch_server inet_tcp_proxy

DIALYZER_OPTS += --src -r test
EUNIT_OPTS = no_tty, {report, {eunit_progress, [colored, profile]}}
include $(if $(ERLANG_MK_FILENAME),$(ERLANG_MK_FILENAME),erlang.mk)
