%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2021 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(seshat).

-export([new_group/1,
         delete_group/1,
         new/3,
         fetch/2,
         overview/1,
         overview/2,
         delete/2,
         format/1
        ]).

-type group() :: term().
-opaque group_ref() :: ets:tid().
-type name() :: term().

-type field_spec() :: {Name :: atom(), Position :: pos_integer(),
                       Type :: counter | gauge, Description :: string()}.

-type format_result() :: #{FieldName :: atom() =>
                           #{type => counter | gauge,
                             help => string(),
                             values => #{name() => integer()}}}.

-export_type([group_ref/0,
              field_spec/0]).

-spec new_group(group()) -> group_ref().
new_group(Group) ->
    seshat_counters_server:create_table(Group).

-spec delete_group(group()) -> ok.
delete_group(Group) ->
    seshat_counters_server:delete_table(Group).

-spec new(group(), name(), [field_spec()]) ->
    counters:counters_ref().
new(Group, Name, Fields) when is_list(Fields) ->
    Size = length(Fields),
    %% TODO: validate that positions are correct, i.e. not out of range
    %% or duplicated
    ExpectedPositions = lists:seq(1, Size),
    Positions = lists:sort([P || {_, P, _, _} <- Fields]),
    case ExpectedPositions == Positions of
        true ->
            CRef = counters:new(Size, [write_concurrency]),
            ok = register_counter(Group, Name, CRef, Fields),
            CRef;
        false ->
            error(invalid_field_specification)
    end.

%% fetch/2 is NOT meant to be called for every counter update.
%% Instead, for higher performance, the consuming application should store the returned counters_ref
%% in a stateful Erlang module or in persistent_term (see persistent:term_put/2).
-spec fetch(group(), name()) -> undefined | counters:counters_ref().
fetch(Group, Name) ->
    TRef = seshat_counters_server:get_table(Group),
    try
        ets:lookup_element(TRef, Name, 2)
    catch
        error:badarg ->
            undefined
    end.

-spec delete(group(), name()) -> ok.
delete(Group, Name) ->
    TRef = seshat_counters_server:get_table(Group),
    true = ets:delete(TRef, Name),
    ok.

-spec overview(group()) ->
    #{name() => #{atom() => integer()}}.
overview(Group) ->
    ets:foldl(
      fun({Name, Ref, Fields}, Acc) ->
              Counters = lists:foldl(
                           fun ({Key, Index, _Type, _Description}, Acc0) ->
                                   Acc0#{Key => counters:get(Ref, Index)}
                           end, #{}, Fields),
              Acc#{Name => Counters}
      end, #{}, seshat_counters_server:get_table(Group)).

-spec overview(group(), name()) ->
    #{atom() => integer()} | undefined.
overview(Group, Name) ->
    case ets:lookup(seshat_counters_server:get_table(Group), Name) of
        [{Name, Ref, Fields}] ->
            lists:foldl(fun ({Key, Index, _Type, _Description}, Acc0) ->
                                Acc0#{Key => counters:get(Ref, Index)}
                        end, #{}, Fields);
        _ ->
            undefined
    end.

-spec format(group()) -> format_result().
format(Group) ->
    ets:foldl(fun({Labels, Ref, Fields}, Acc) ->
                      lists:foldl(
                        fun ({Name, Index, Type, Help}, Acc0) ->
                                InitialMetric = #{type => Type,
                                                  help => Help,
                                                  values => #{}},
                                Metric = maps:get(Name, Acc0, InitialMetric),
                                Values = maps:get(values, Metric),
                                Counter = counters:get(Ref, Index),
                                Values1 = Values#{Labels => Counter},
                                Metric1 = Metric#{values => Values1},
                                Acc0#{Name => Metric1}
                        end, Acc, Fields)
              end, #{}, seshat_counters_server:get_table(Group)).

%% internal

register_counter(Group, Name, Ref, Fields) ->
    TRef = seshat_counters_server:get_table(Group),
    true = ets:insert(TRef, {Name, Ref, Fields}),
    ok.
