%%%------------------------------------------------------------------------
%% A vendored + patched copy of `otel_log_handler` from `:opentelemetry_experimental`.
%%
%% Why this exists:
%% - The upstream handler can get stuck in the `exporting` state when the
%%   export timer fires while the batch is empty. Once stuck, it will never
%%   export logs again, even when new log events arrive.
%% - We fix that by transitioning back to `idle` on an empty-batch export tick.
%% - We also avoid linking the handler process to logger's short-lived caller.
%%
%% Queue / OOM guard (2026-09-16):
%% Upstream never consults `max_queue_size`, and it runs the OTLP export
%% *inside* the gen_statem. A slow sanitize or a hung `grpcbox_client:recv_end`
%% then lets every subsequent `log/2` cast pile up in the mailbox until the
%% cgroup OOMs (observed: ~90k casts, multi-GiB handler). Export now runs in a
%% monitored runner with a hard timeout; new events are dropped once the batch
%% or the mailbox is full. Do not log at warning+ from this module: those
%% records re-enter this handler and recreate the feedback loop.
%%%-------------------------------------------------------------------------
-module(serviceradar_otel_log_handler_v2).

-behaviour(gen_statem).

-include_lib("opentelemetry_api/include/opentelemetry.hrl").

-export([start/2]).

-export([log/2,
         adding_handler/1,
         removing_handler/1,
         changing_config/3,
         filter_config/1,
         queue_stats/1]).

-export([init/1,
         callback_mode/0,
         idle/3,
         exporting/3,
         handle_event/3]).

-type config() :: #{id => logger:handler_id(),
                    regname := atom(),
                    config => term(),
                    level => logger:level() | all | none,
                    module => module(),
                    filter_default => log | stop,
                    filters => [{logger:filter_id(), logger:filter()}],
                    formatter => {module(), logger:formatter_config()}}.

%% Event-count cap (not bytes). Upstream divided by wordsize, which made the
%% configured 2048 into 256 and then never used it.
-define(DEFAULT_MAX_QUEUE_SIZE, 512).
-define(DEFAULT_SCHEDULED_DELAY_MS, timer:seconds(5)).
-define(DEFAULT_EXPORTER_TIMEOUT_MS, timer:seconds(10)).
-define(MAILBOX_DROP_QLEN, 256).

-define(name_to_reg_name(Module, Id),
        list_to_atom(lists:concat([Module, "_", Id]))).

-record(data, {exporter             :: {module(), term()} | undefined,
               exporter_config      :: {module(), term()} | undefined,
               resource             :: otel_resource:t(),

               runner_pid           :: pid() | undefined,
               max_queue_size       :: integer() | infinity,
               exporting_timeout_ms :: integer(),
               scheduled_delay_ms   :: integer(),

               config :: #{},
               batch_len :: non_neg_integer(),
               batch  :: #{opentelemetry:instrumentation_scope() => [logger:log_event()]}}).

%% NOTE: This is intentionally *not* linked to the caller. Logger may invoke
%% `adding_handler/1` from a short-lived process; linking would race with our
%% `trap_exit` setup and can kill the handler right after startup.
start(RegName, Config) ->
    gen_statem:start({local, RegName}, ?MODULE, [RegName, Config], []).

-spec adding_handler(Config) -> {ok, Config} | {error, Reason} when
      Config :: config(),
      Reason :: term().
adding_handler(#{id := Id,
                 module := Module}=Config) ->
    RegName = ?name_to_reg_name(Module, Id),
    case ?MODULE:start(RegName, Config) of
        {ok, _Pid} ->
            {ok, Config#{regname => RegName}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec changing_config(SetOrUpdate, OldConfig, NewConfig) ->
          {ok,Config} | {error,Reason} when
      SetOrUpdate :: set | update,
      OldConfig :: config(),
      NewConfig :: config(),
      Config :: config(),
      Reason :: term().
changing_config(SetOrUpdate, OldConfig, NewConfig=#{regname := Id}) ->
    gen_statem:call(Id, {changing_config, SetOrUpdate, OldConfig, NewConfig}).

-spec removing_handler(Config) -> ok when
      Config :: config().
removing_handler(Config=#{regname := Id}) ->
    _ = catch gen_statem:call(Id, {removing_handler, Config}),
    _ = catch gen_statem:stop(Id, shutdown, 5000),
    ok.

-spec queue_stats(atom()) -> #{batch_len := non_neg_integer(),
                               max_queue_size := integer() | infinity,
                               mailbox := non_neg_integer()}.
queue_stats(RegName) ->
    gen_statem:call(RegName, queue_stats).

-spec log(LogEvent, Config) -> ok when
      LogEvent :: logger:log_event(),
      Config :: config().
log(LogEvent, _Config=#{regname := Id}) ->
    case whereis(Id) of
        undefined ->
            ok;
        Pid ->
            case process_info(Pid, message_queue_len) of
                {message_queue_len, QLen} when QLen >= ?MAILBOX_DROP_QLEN ->
                    ok;
                _ ->
                    Scope = case LogEvent of
                                #{meta := #{otel_scope := Scope0=#instrumentation_scope{}}} ->
                                    Scope0;
                                #{meta := #{mfa := {Module, _, _}}} ->
                                    opentelemetry:get_application_scope(Module);
                                _ ->
                                    opentelemetry:instrumentation_scope(<<>>, <<>>, <<>>)
                            end,
                    gen_statem:cast(Id, {log, Scope, LogEvent})
            end
    end.

-spec filter_config(Config) -> Config when
      Config :: config().
filter_config(Config=#{regname := Id}) ->
    gen_statem:call(Id, {filter_config, Config}).

init([_RegName, Config]) ->
    process_flag(trap_exit, true),

    Resource = otel_resource_detector:get_resource(),

    SizeLimit = maps:get(max_queue_size, Config, ?DEFAULT_MAX_QUEUE_SIZE),
    ExportingTimeout = maps:get(exporting_timeout_ms, Config, ?DEFAULT_EXPORTER_TIMEOUT_MS),
    ScheduledDelay = maps:get(scheduled_delay_ms, Config, ?DEFAULT_SCHEDULED_DELAY_MS),

    ExporterConfig = maps:get(exporter, Config, {opentelemetry_exporter, #{protocol => grpc}}),

    {ok, idle, #data{exporter=undefined,
                     exporter_config=ExporterConfig,
                     resource=Resource,
                     config=Config,
                     max_queue_size=SizeLimit,
                     exporting_timeout_ms=ExportingTimeout,
                     scheduled_delay_ms=ScheduledDelay,
                     batch_len=0,
                     batch=#{}}}.

callback_mode() ->
    [state_functions, state_enter].

idle(enter, _OldState, Data=#data{exporter=undefined,
                                  exporter_config=ExporterConfig,
                                  scheduled_delay_ms=SendInterval}) ->
    Exporter = init_exporter(ExporterConfig),
    {keep_state, Data#data{exporter=Exporter},
     [{{timeout, export_logs}, SendInterval, export_logs}]};
idle(enter, _OldState, #data{scheduled_delay_ms=SendInterval}) ->
    {keep_state_and_data, [{{timeout, export_logs}, SendInterval, export_logs}]};
idle(_, export_logs, Data=#data{exporter=undefined,
                                 exporter_config=ExporterConfig}) ->
    Exporter = init_exporter(ExporterConfig),
    {next_state, exporting, Data#data{exporter=Exporter}, [{next_event, internal, export}]};
idle(_, export_logs, Data) ->
    {next_state, exporting, Data, [{next_event, internal, export}]};
idle(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

exporting({timeout, export_logs}, export_logs, _) ->
    {keep_state_and_data, [postpone]};
exporting(enter, _OldState, _Data) ->
    keep_state_and_data;
exporting(internal, export, Data=#data{batch=Batch}) when map_size(Batch) =/= 0 ->
    {keep_state, spawn_export(Data),
     [{{timeout, export_watch}, Data#data.exporting_timeout_ms, export_timeout}]};
%% Patch: if the batch is empty, return to idle so the next timer tick
%% can schedule exports normally. Without this, the state machine can get stuck
%% in `exporting` forever after an empty export tick.
exporting(internal, export, Data) ->
    {next_state, idle, Data};
exporting({timeout, export_watch}, export_timeout, Data=#data{runner_pid=Pid}) when is_pid(Pid) ->
    exit(Pid, kill),
    {next_state, idle, Data#data{runner_pid=undefined}};
exporting({timeout, export_watch}, export_timeout, Data) ->
    {next_state, idle, Data};
exporting(info, {'DOWN', _MRef, process, Pid, _Reason}, Data=#data{runner_pid=Pid}) ->
    {next_state, idle, Data#data{runner_pid=undefined}};
exporting(info, {'DOWN', _MRef, process, _Pid, _Reason}, _Data) ->
    keep_state_and_data;
exporting(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

handle_event({call, From}, {changing_config, _SetOrUpdate, _OldConfig, NewConfig}, Data) ->
    {keep_state, Data#data{config=NewConfig}, [{reply, From, NewConfig}]};
handle_event({call, From}, {removing_handler, Config}, _Data) ->
    {keep_state_and_data, [{reply, From, Config}]};
handle_event({call, From}, {filter_handler, Config}, Data) ->
    {keep_state, Data, [{reply, From, Config}]};
handle_event({call, From}, {filter_config, Config}, Data) ->
    {keep_state, Data, [{reply, From, Config}]};
handle_event({call, From}, queue_stats, #data{batch_len=Len, max_queue_size=Max}) ->
    Mailbox = case process_info(self(), message_queue_len) of
                  {message_queue_len, Q} -> Q;
                  _ -> 0
              end,
    {keep_state_and_data,
     [{reply, From, #{batch_len => Len, max_queue_size => Max, mailbox => Mailbox}}]};
handle_event({call, _From}, _Msg, _Data) ->
    keep_state_and_data;
handle_event(cast, {log, Scope, LogEvent},
             Data=#data{batch=Logs, batch_len=Len, max_queue_size=Max}) ->
    case queue_full(Len, Max) of
        true ->
            keep_state_and_data;
        false ->
            {keep_state, Data#data{
                batch=maps:update_with(Scope, fun(V) -> [LogEvent | V] end, [LogEvent], Logs),
                batch_len=Len + 1
            }}
    end;
handle_event(_, _, _) ->
    keep_state_and_data.

%%

queue_full(_Len, infinity) ->
    false;
queue_full(Len, Max) when is_integer(Max), Len >= Max ->
    true;
queue_full(_Len, _Max) ->
    false.

spawn_export(Data=#data{exporter=Exporter,
                        resource=Resource,
                        config=Config,
                        batch=Batch}) ->
    Runner = spawn(fun() ->
                           export(Exporter, Resource, Batch, Config)
                   end),
    monitor(process, Runner),
    Data#data{runner_pid=Runner, batch=#{}, batch_len=0}.

init_exporter(undefined) ->
    undefined;
init_exporter(none) ->
    undefined;
init_exporter(ExporterConfig) ->
    case otel_exporter:init(ExporterConfig) of
        Exporter when Exporter =/= undefined andalso Exporter =/= none ->
            Exporter;
        _ ->
            undefined
    end.

export(undefined, _, _, _) ->
    true;
export({ExporterModule, ExporterConfig}, Resource, Batch, Config) ->
    %% don't let an exporter exception crash us
    %% and return true if exporter failed
    try
        otel_exporter:export_logs(ExporterModule, {Batch, Config}, Resource, ExporterConfig)
            =:= failed_not_retryable
    catch
        _Kind:_Reason:_StackTrace ->
            %% INFO on purpose: warning+ is this handler's own level and would
            %% re-enter the mailbox we are trying to drain.
            true
    end.
