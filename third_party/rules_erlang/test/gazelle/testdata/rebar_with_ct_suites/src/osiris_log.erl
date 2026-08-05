%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(osiris_log).

-include("osiris.hrl").
-include_lib("kernel/include/file.hrl").

-export([init/1,
         init/2,
         init_acceptor/3,
         write/2,
         write/3,
         write/5,
         recover_tracking/1,
         accept_chunk/2,
         next_offset/1,
         first_offset/1,
         first_timestamp/1,
         tail_info/1,
         evaluate_tracking_snapshot/2,
         send_file/2,
         send_file/3,
         init_data_reader/2,
         init_offset_reader/2,
         read_header/1,
         read_chunk/1,
         read_chunk_parsed/1,
         read_chunk_parsed/2,
         committed_offset/1,
         set_committed_chunk_id/2,
         get_current_epoch/1,
         get_directory/1,
         get_name/1,
         get_shared/1,
         get_default_max_segment_size_bytes/0,
         counters_ref/1,
         close/1,
         overview/1,
         format_status/1,
         update_retention/2,
         evaluate_retention/2,
         directory/1,
         delete_directory/1]).

-ifdef(TEST).
-export([part_test/0]).
-endif.

% maximum size of a segment in bytes
-define(DEFAULT_MAX_SEGMENT_SIZE_B, 500 * 1000 * 1000).
% maximum number of chunks per segment
-define(DEFAULT_MAX_SEGMENT_SIZE_C, 256_000).
-define(INDEX_RECORD_SIZE_B, 29).
-define(C_OFFSET, 1).
-define(C_FIRST_OFFSET, 2).
-define(C_FIRST_TIMESTAMP, 3).
-define(C_CHUNKS, 4).
-define(C_SEGMENTS, 5).
-define(COUNTER_FIELDS,
        [
         {offset, ?C_OFFSET, counter, "The last offset (not chunk id) in the log for writers. The last offset read for readers"
         },
         {first_offset, ?C_FIRST_OFFSET, counter, "First offset, not updated for readers"},
         {first_timestamp, ?C_FIRST_TIMESTAMP, counter, "First timestamp, not updated for readers"},
         {chunks, ?C_CHUNKS, counter, "Number of chunks read or written, incremented even if a reader only reads the header"},
         {segments, ?C_SEGMENTS, counter, "Number of segments"}
        ]
       ).

%% Specification of the Log format.
%%
%% Notes:
%%   * All integers are in Big Endian order.
%%   * Timestamps are expressed in milliseconds.
%%   * Timestamps are stored in signed 64-bit integers.
%%
%% Log format
%% ==========
%%
%%   |0              |1              |2              |3              | Bytes
%%   |0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7| Bits
%%   +---------------+---------------+---------------+---------------+
%%   | Log magic (0x4f53494c = "OSIL")                               |
%%   +---------------------------------------------------------------+
%%   | Log version (0x00000001)                                      |
%%   +---------------------------------------------------------------+
%%   | Contiguous list of Chunks                                     |
%%   : (until EOF)                                                   :
%%   :                                                               :
%%   +---------------------------------------------------------------+
%%
%% Chunk format
%% ============
%%
%% A chunk is the unit of replication and read.
%%
%%   |0              |1              |2              |3              | Bytes
%%   |0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7| Bits
%%   +-------+-------+---------------+---------------+---------------+
%%   | Mag   | Ver   | Chunk type    | Number of entries             |
%%   +-------+-------+---------------+-------------------------------+
%%   | Number of records                                             |
%%   +---------------------------------------------------------------+
%%   | Timestamp                                                     |
%%   | (8 bytes)                                                     |
%%   +---------------------------------------------------------------+
%%   | Epoch                                                         |
%%   | (8 bytes)                                                     |
%%   +---------------------------------------------------------------+
%%   | ChunkId                                                       |
%%   | (8 bytes)                                                     |
%%   +---------------------------------------------------------------+
%%   | Data CRC                                                      |
%%   +---------------------------------------------------------------+
%%   | Data length                                                   |
%%   +---------------------------------------------------------------+
%%   | Trailer length                                                |
%%   +---------------------------------------------------------------+
%%   | Reserved                                                      |
%%   +---------------------------------------------------------------+
%%   | Contiguous list of Data entries                               |
%%   : (<data length> bytes)                                         :
%%   :                                                               :
%%   +---------------------------------------------------------------+
%%   | Contiguous list of Trailer entries                            |
%%   : (<trailer length> bytes)                                      :
%%   :                                                               :
%%   +---------------------------------------------------------------+
%%
%% Mag = 0x5
%%   Magic number to identify the beginning of a chunk
%%
%% Ver = 0x1
%%   Version of the chunk format
%%
%% Chunk type = CHNK_USER (0x00) |
%%              CHNK_TRK_DELTA (0x01) |
%%              CHNK_TRK_SNAPSHOT (0x02)
%%   Type which determines what to do with entries.
%%
%% Number of entries = unsigned 16-bit integer
%%   Number of entries in the data section following the chunk header.
%%
%% Number of records = unsigned 32-bit integer
%%
%% Timestamp = signed 64-bit integer
%%
%% Epoch = unsigned 64-bit integer
%%
%% ChunkId = unsigned 64-bit integer, the first offset in the chunk
%%
%% Data CRC = unsigned 32-bit integer
%%
%% Data length = unsigned 32-bit integer
%%
%% Trailer length = unsigned 32-bit integer
%%
%% Reserved = 4 bytes reserved for future extensions
%%
%% Data Entry format
%% =================
%%
%%   |0              |1              |2              |3              | Bytes
%%   |0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7| Bits
%%   +---------------+---------------+---------------+---------------+
%%   |T| Data entry header and body                                  |
%%   +-+ (format and length depends on the chunk and entry types)    :
%%   :                                                               :
%%   :                                                               :
%%   +---------------------------------------------------------------+
%%
%% T = SimpleEntry (0) |
%%     SubBatchEntry (1)
%%
%% SimpleEntry (CHNK_USER)
%% -----------------------
%%
%%   |0              |1              |2              |3              | Bytes
%%   |0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7| Bits
%%   +---------------+---------------+---------------+---------------+
%%   |0| Entry body length                                           |
%%   +-+-------------------------------------------------------------+
%%   | Entry body                                                    :
%%   : (<body length> bytes)                                         :
%%   :                                                               :
%%   +---------------------------------------------------------------+
%%
%% Entry body length = unsigned 31-bit integer
%%
%% Entry body = arbitrary data
%%
%% SimpleEntry (CHNK_TRK_SNAPSHOT)
%% -------------------------------------------------
%%
%%   |0              |1              |2              |3              | Bytes
%%   |0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7| Bits
%%   +-+-------------+---------------+---------------+---------------+
%%   |0| Entry body length                                           |
%%   +-+-------------------------------------------------------------+
%%   | Entry Body                                                    |
%%   : (<body length> bytes)                                         :
%%   :                                                               :
%%   +---------------------------------------------------------------+
%%
%% The entry body is made of a contiguous list of the following block, until
%% the body length is reached.
%%
%%   |0              |1              |2              |3              | Bytes
%%   |0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7| Bits
%%   +---------------+---------------+---------------+---------------+
%%   | Trk    type   | ID size       | ID                            |
%%   +---------------+---------------+                               |
%%   |                                                               |
%%   :                                                               :
%%   +---------------------------------------------------------------+
%%   | Type specific data                                            |
%%   |                                                               |
%%   +---------------------------------------------------------------+
%%
%% ID type = unsigned 8-bit integer 0 = sequence, 1 = offset
%%
%% ID size = unsigned 8-bit integer
%%
%% ID = arbitrary data
%%
%% Type specific data:
%% When ID type = 0: ChunkId, Sequence = unsigned 64-bit integers
%% When ID type = 1: Offset = unsigned 64-bit integer
%%
%%
%% SubBatchEntry (CHNK_USER)
%% -------------------------
%%
%%   |0              |1              |2              |3              | Bytes
%%   |0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7| Bits
%%   +-+-----+-------+---------------+---------------+---------------+
%%   |1| Cmp | Rsvd  | Number of records             | Uncmp Length..|
%%   +-+-----+-------+-------------------------------+---------------+
%%   | Uncompressed Length                           | Length  (...) |
%%   +-+-----+-------+-------------------------------+---------------+
%%   | Length                                        | Body          |
%%   +-+---------------------------------------------+               +
%%   | Body                                                          |
%%   :                                                               :
%%   +---------------------------------------------------------------+
%%
%% Cmp = unsigned 3-bit integer
%%   Compression type
%%
%% Rsvd = 0x0
%%   Reserved bits
%%
%% Number of records = unsigned 16-bit integer
%%
%% Uncompressed Length = unsigned 32-bit integer
%% Length = unsigned 32-bit integer
%%
%% Body = arbitrary data
%%
%% Tracking format
%% ==============
%%
%% Tracking is made of a contiguous list of the following block,
%% until the trailer length stated in the chunk header is reached.
%% The same format is used for the CHNK_TRK_DELTA chunk entry.
%%
%%   |0              |1              |2              |3              | Bytes
%%   |0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7| Bits
%%   +-+-------------+---------------+---------------+---------------+
%%   | Tracking type |TrackingID size| TrackingID                    |
%%   +---------------+---------------+                               |
%%   |                                                               |
%%   :                                                               :
%%   +---------------------------------------------------------------+
%%   | Tracking data                                                 |
%%   |                                                               |
%%   +---------------------------------------------------------------+
%%
%%
%% Tracking type: 0 = sequence, 1 = offset, 2 = timestamp
%%
%% Tracking type 0 = sequence to track producers for msg deduplication
%% use case: producer sends msg -> osiris persists msg -> confirm doens't reach producer -> producer resends same msg
%%
%% Tracking type 1 = offset to track consumers
%% use case: consumer or server restarts -> osiris knows offset where consumer needs to resume
%%
%% Tracking data: 64 bit integer
%%
%% Index format
%% ============
%%
%% Each index record in the index file maps to a chunk in the segment file.
%%
%% Index record
%% ------------
%%
%%   |0              |1              |2              |3              | Bytes
%%   |0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7|0 1 2 3 4 5 6 7| Bits
%%   +---------------+---------------+---------------+---------------+
%%   | Offset                                                        |
%%   | (8 bytes)                                                     |
%%   +---------------------------------------------------------------+
%%   | Timestamp                                                     |
%%   | (8 bytes)                                                     |
%%   +---------------------------------------------------------------+
%%   | Epoch                                                         |
%%   | (8 bytes)                                                     |
%%   +---------------------------------------------------------------+
%%   | File Offset                                                   |
%%   +---------------+-----------------------------------------------+
%%   | Chunk Type    |
%%   +---------------+

-type offset() :: osiris:offset().
-type epoch() :: osiris:epoch().
-type range() :: empty | {From :: offset(), To :: offset()}.
-type counter_spec() :: {Tag :: term(), Fields :: [atom()]}.
-type chunk_type() ::
    ?CHNK_USER |
    ?CHNK_TRK_DELTA |
    ?CHNK_TRK_SNAPSHOT.
-type config() ::
    osiris:config() |
    #{dir := file:filename_all(),
      epoch => non_neg_integer(),
      % first_offset_fun => fun((integer()) -> ok),
      shared => atomics:atomics_ref(),
      max_segment_size_bytes => non_neg_integer(),
      %% max number of writer ids to keep around
      tracking_config => osiris_tracking:config(),
      counter_spec => counter_spec(),
      %% used when initialising a log from an offset other than 0
      initial_offset => osiris:offset(),
      %% a cached list of the index files for a given log
      %% avoids scanning disk for files multiple times if already know
      %% e.g. in init_acceptor
      index_files => [file:filename_all()]}.
-type record() :: {offset(), osiris:data()}.
-type offset_spec() :: osiris:offset_spec().
-type retention_spec() :: osiris:retention_spec().
-type header_map() ::
    #{chunk_id => offset(),
      epoch => epoch(),
      type => chunk_type(),
      crc => integer(),
      num_records => non_neg_integer(),
      num_entries => non_neg_integer(),
      timestamp => osiris:timestamp(),
      data_size => non_neg_integer(),
      trailer_size => non_neg_integer(),
      header_data => binary(),
      position => non_neg_integer()}.
-type transport() :: tcp | ssl.

%% holds static or rarely changing fields
-record(cfg,
        {directory :: file:filename_all(),
         name :: osiris:name(),
         max_segment_size_bytes = ?DEFAULT_MAX_SEGMENT_SIZE_B :: non_neg_integer(),
         max_segment_size_chunks = ?DEFAULT_MAX_SEGMENT_SIZE_C :: non_neg_integer(),
         tracking_config = #{} :: osiris_tracking:config(),
         retention = [] :: [osiris:retention_spec()],
         counter :: counters:counters_ref(),
         counter_id :: term(),
         %% the maximum number of active writer deduplication sessions
         %% that will be included in snapshots written to new segments
         readers_counter_fun = fun(_) -> ok end :: function(),
         shared :: atomics:atomics_ref()
         }).
-record(read,
        {type :: data | offset,
         next_offset = 0 :: offset(),
         transport :: transport(),
         chunk_selector :: all | user_data}).
-record(write,
        {type = writer :: writer | acceptor,
         segment_size = {?LOG_HEADER_SIZE, 0} :: {non_neg_integer(), non_neg_integer()},
         current_epoch :: non_neg_integer(),
         tail_info = {0, empty} :: osiris:tail_info()
        }).
% -record(segment,
%         {
%          current_file :: undefined | file:filename(),
%          index_fd :: undefined | file:io_device(),
%          fd :: undefined | file:io_device()}).
-record(?MODULE,
        {cfg :: #cfg{},
         mode :: #read{} | #write{},
         current_file :: undefined | file:filename_all(),
         index_fd :: undefined | file:io_device(),
         fd :: undefined | file:io_device()
        }).
%% record chunk_info does not map exactly to an index record (field 'num' differs)
-record(chunk_info,
        {id :: offset(),
         timestamp :: non_neg_integer(),
         epoch :: epoch(),
         num :: non_neg_integer(),
         type :: chunk_type(),
         %% size of data + trailer
         size :: non_neg_integer(),
         %% position in segment file
         pos :: integer()
        }).
-record(seg_info,
        {file :: file:filename_all(),
         size = 0 :: non_neg_integer(),
         index :: file:filename_all(),
         first :: undefined | #chunk_info{},
         last :: undefined | #chunk_info{}}).

-opaque state() :: #?MODULE{}.

-export_type([state/0,
              range/0,
              config/0,
              counter_spec/0]).

-spec directory(osiris:config() | list()) -> file:filename_all().
directory(#{name := Name, dir := Dir}) ->
    filename:join(Dir, Name);
directory(#{name := Name}) ->
    {ok, Dir} = application:get_env(osiris, data_dir),
    filename:join(Dir, Name);
directory(Name) when ?IS_STRING(Name) ->
    {ok, Dir} = application:get_env(osiris, data_dir),
    filename:join(Dir, Name).

-spec init(config()) -> state().
init(Config) ->
    init(Config, writer).

-spec init(config(), writer | acceptor) -> state().
init(#{dir := Dir,
       name := Name,
       epoch := Epoch} = Config,
     WriterType) ->
    %% scan directory for segments if in write mode
    MaxSizeBytes =
        maps:get(max_segment_size_bytes, Config, ?DEFAULT_MAX_SEGMENT_SIZE_B),
    MaxSizeChunks = application:get_env(osiris, max_segment_size_chunks,
                                        ?DEFAULT_MAX_SEGMENT_SIZE_C),
    Retention = maps:get(retention, Config, []),
    ?INFO("Stream: ~s will use ~s for osiris log data directory",
          [Name, Dir]),
    ?DEBUG("osiris_log:init/1 stream ~s max_segment_size_bytes: ~b,
           max_segment_size_chunks ~b, retention ~w",
          [Name, MaxSizeBytes, MaxSizeChunks, Retention]),
    ok = filelib:ensure_dir(Dir),
    case file:make_dir(Dir) of
        ok ->
            ok;
        {error, eexist} ->
            ok;
        Err ->
            throw(Err)
    end,

    Cnt = make_counter(Config),
    %% initialise offset counter to -1 as 0 is the first offset in the log and
    %% it hasn't necessarily been written yet, for an empty log the first offset
    %% is initialised to 0 however and will be updated after each retention run.
    counters:put(Cnt, ?C_OFFSET, -1),
    counters:put(Cnt, ?C_SEGMENTS, 0),
    Shared = osiris_log_shared:new(),
    Cfg = #cfg{directory = Dir,
               name = Name,
               max_segment_size_bytes = MaxSizeBytes,
               max_segment_size_chunks = MaxSizeChunks,
               tracking_config = maps:get(tracking_config, Config, #{}),
               retention = Retention,
               counter = Cnt,
               counter_id = counter_id(Config),
               shared = Shared},
    ok = maybe_fix_corrupted_files(Config),
    case first_and_last_seginfos(Config) of
        none ->
            NextOffset = case Config of
                             #{initial_offset := IO}
                               when WriterType == acceptor ->
                                 IO;
                             _ ->
                                 0
                         end,
            osiris_log_shared:set_first_chunk_id(Shared, NextOffset - 1),
            open_new_segment(#?MODULE{cfg = Cfg,
                                      mode =
                                          #write{type = WriterType,
                                                 tail_info = {NextOffset, empty},
                                                 current_epoch = Epoch}});
        {NumSegments,
         #seg_info{first = #chunk_info{id = FstChId,
                                       timestamp = FstTs}},
         #seg_info{file = Filename,
                   index = IdxFilename,
                   size = Size,
                   last = #chunk_info{epoch = LastEpoch,
                                      timestamp = LastTs,
                                      id = LastChId,
                                      num = LastNum}}} ->
            %% assert epoch is same or larger
            %% than last known epoch
            case LastEpoch > Epoch of
                true ->
                    exit({invalid_epoch, LastEpoch, Epoch});
                _ ->
                    ok
            end,
            TailInfo = {LastChId + LastNum,
                        {LastEpoch, LastChId, LastTs}},

            counters:put(Cnt, ?C_FIRST_OFFSET, FstChId),
            counters:put(Cnt, ?C_FIRST_TIMESTAMP, FstTs),
            counters:put(Cnt, ?C_OFFSET, LastChId + LastNum - 1),
            counters:put(Cnt, ?C_SEGMENTS, NumSegments),
            osiris_log_shared:set_first_chunk_id(Shared, FstChId),
            osiris_log_shared:set_last_chunk_id(Shared, LastChId),
            ?DEBUG("~s:~s/~b: ~s next offset ~b first offset ~b",
                   [?MODULE,
                    ?FUNCTION_NAME,
                    ?FUNCTION_ARITY,
                    Name,
                    element(1, TailInfo),
                    FstChId]),
            {ok, SegFd} = open(Filename, ?FILE_OPTS_WRITE),
            {ok, Size} = file:position(SegFd, Size),
            %% maybe_fix_corrupted_files has truncated the index to the last record poiting
            %% at a valid chunk we can now truncate the segment to size in case there is trailing data
            ok = file:truncate(SegFd),
            {ok, IdxFd} = open(IdxFilename, ?FILE_OPTS_WRITE),
            {ok, IdxEof} = file:position(IdxFd, eof),
            NumChunks = (IdxEof - ?IDX_HEADER_SIZE) div ?INDEX_RECORD_SIZE_B,
            #?MODULE{cfg = Cfg,
                     mode =
                         #write{type = WriterType,
                                tail_info = TailInfo,
                                segment_size = {Size, NumChunks},
                                current_epoch = Epoch},
                     current_file = filename:basename(Filename),
                     fd = SegFd,
                     index_fd = IdxFd};
        {1, #seg_info{file = Filename,
                      index = IdxFilename,
                      last = undefined}, _} ->
            %% the empty log case
            {ok, SegFd} = open(Filename, ?FILE_OPTS_WRITE),
            {ok, IdxFd} = open(IdxFilename, ?FILE_OPTS_WRITE),
            %% TODO: do we potentially need to truncate the segment
            %% here too?
            {ok, _} = file:position(SegFd, eof),
            {ok, _} = file:position(IdxFd, eof),
            osiris_log_shared:set_first_chunk_id(Shared, -1),
            #?MODULE{cfg = Cfg,
                     mode =
                         #write{type = WriterType,
                                tail_info = {0, empty},
                                current_epoch = Epoch},
                     current_file = filename:basename(Filename),
                     fd = SegFd,
                     index_fd = IdxFd}
    end.

maybe_fix_corrupted_files([]) ->
    ok;
maybe_fix_corrupted_files(#{dir := Dir}) ->
    ok = maybe_fix_corrupted_files(sorted_index_files(Dir));
maybe_fix_corrupted_files([IdxFile]) ->
    SegFile = segment_from_index_file(IdxFile),
    ok = truncate_invalid_idx_records(IdxFile, file_size(SegFile)),
    case file_size(IdxFile) =< ?IDX_HEADER_SIZE + ?INDEX_RECORD_SIZE_B of
        true ->
            % the only index doesn't contain a single valid record
            % make sure it has a valid header
            {ok, IdxFd} = file:open(IdxFile, ?FILE_OPTS_WRITE),
            ok = file:write(IdxFd, ?IDX_HEADER),
            ok = file:close(IdxFd);
        false ->
            ok
    end,
    case file_size(SegFile) =< ?LOG_HEADER_SIZE + ?HEADER_SIZE_B of
        true ->
            % the only segment doesn't contain a single valid chunk
            % make sure it has a valid header
            {ok, SegFd} = file:open(SegFile, ?FILE_OPTS_WRITE),
            ok = file:write(SegFd, ?LOG_HEADER),
            ok = file:close(SegFd);
        false ->
            ok
    end;
maybe_fix_corrupted_files(IdxFiles) ->
    LastIdxFile = lists:last(IdxFiles),
    LastSegFile = segment_from_index_file(LastIdxFile),
    case file_size(LastSegFile) of
        N when N =< ?HEADER_SIZE_B ->
            % if the segment doesn't contain any chunks, just delete it
            ?WARNING("deleting an empty segment file: ~p", [LastSegFile]),
            ok = prim_file:delete(LastIdxFile),
            ok = prim_file:delete(LastSegFile),
            maybe_fix_corrupted_files(IdxFiles -- [LastIdxFile]);
        LastSegFileSize ->
            ok = truncate_invalid_idx_records(LastIdxFile, LastSegFileSize)
    end.

non_empty_index_files([]) ->
    [];
non_empty_index_files(IdxFiles) ->
    LastIdxFile = lists:last(IdxFiles),
    case file_size(LastIdxFile) of
        N when N =< ?IDX_HEADER_SIZE ->
            non_empty_index_files(IdxFiles -- [LastIdxFile]);
        _ ->
            IdxFiles
    end.

truncate_invalid_idx_records(IdxFile, SegSize) ->
    % TODO currently, if we have no valid index records,
    % we truncate the segment, even though it could theoretically
    % contain valid chunks. This should never happen in normal
    % operations, since we write to the index first
    % and fsync it first. However, it feels wrong, since we can
    % reconstruct the index from a segment. We should probably
    % add an option to perform a full segment scan and reconstruct
    % the index for the valid chunks.
    SegFile = segment_from_index_file(IdxFile),
    {ok, IdxFd} = open(IdxFile, [raw, binary, write, read]),
    {ok, Pos} = position_at_idx_record_boundary(IdxFd, eof),
    ok = skip_invalid_idx_records(IdxFd, SegFile, SegSize, Pos),
    ok = file:truncate(IdxFd),
    file:close(IdxFd).

skip_invalid_idx_records(IdxFd, SegFile, SegSize, Pos) ->
    case Pos >= ?IDX_HEADER_SIZE + ?INDEX_RECORD_SIZE_B of
        true ->
            {ok, _} = file:position(IdxFd, Pos - ?INDEX_RECORD_SIZE_B),
            case file:read(IdxFd, ?INDEX_RECORD_SIZE_B) of
                {ok, <<0:(?INDEX_RECORD_SIZE_B*8)>>} ->
                    % trailing zeros found
                    skip_invalid_idx_records(IdxFd, SegFile, SegSize,
                                             Pos - ?INDEX_RECORD_SIZE_B);
                {ok, <<_ChunkId:64/unsigned,
                       _Timestamp:64/signed,
                       _Epoch:64/unsigned,
                       ChunkPos:32/unsigned,
                       _ChType:8/unsigned>>} ->
                    % a non-zero index record
                    case ChunkPos < SegSize andalso
                         is_valid_chunk_on_disk(SegFile, ChunkPos) of
                        true ->
                            ok;
                        false ->
                            % this chunk doesn't exist in the segment or is invalid
                            skip_invalid_idx_records(IdxFd, SegFile, SegSize, Pos - ?INDEX_RECORD_SIZE_B)
                    end;
                Err ->
                    Err
            end;
        false ->
            %% TODO should we validate the correctness of index/segment headers?
            {ok, _} = file:position(IdxFd, ?IDX_HEADER_SIZE),
            ok
    end.

-spec write([osiris:data()], state()) -> state().
write(Entries, State) when is_list(Entries) ->
    Timestamp = erlang:system_time(millisecond),
    write(Entries, ?CHNK_USER, Timestamp, <<>>, State).

-spec write([osiris:data()], integer(), state()) -> state().
write(Entries, Now, #?MODULE{mode = #write{}} = State)
    when is_integer(Now) ->
    write(Entries, ?CHNK_USER, Now, <<>>, State).

-spec write([osiris:data()], chunk_type(), osiris:timestamp(),
            iodata(), state()) -> state().
write([_ | _] = Entries,
      ChType,
      Now,
      Trailer,
      #?MODULE{cfg = #cfg{},
               mode =
                   #write{current_epoch = Epoch, tail_info = {Next, _}} =
                       _Write0} =
          State0)
    when is_integer(Now) andalso
         is_integer(ChType) ->
    %% The osiris writer always pass Entries in the reversed order
    %% in order to avoid unnecessary lists rev|trav|ersals
    {ChunkData, NumRecords} =
        make_chunk(Entries, Trailer, ChType, Now, Epoch, Next),
    write_chunk(ChunkData, ChType, Now, Epoch, NumRecords, State0);
write([], _ChType, _Now, _Trailer, #?MODULE{} = State) ->
    State.

-spec accept_chunk(iodata(), state()) -> state().
accept_chunk([<<?MAGIC:4/unsigned,
                ?VERSION:4/unsigned,
                ChType:8/unsigned,
                _NumEntries:16/unsigned,
                NumRecords:32/unsigned,
                Timestamp:64/signed,
                Epoch:64/unsigned,
                Next:64/unsigned,
                Crc:32/integer,
                DataSize:32/unsigned,
                _TrailerSize:32/unsigned,
                _Reserved:32,
                Data/binary>>
              | DataParts] =
                 Chunk,
             #?MODULE{cfg = #cfg{}, mode = #write{tail_info = {Next, _}}} =
                 State0) ->
    DataAndTrailer = [Data | DataParts],
    validate_crc(Next, Crc, part(DataSize, DataAndTrailer)),
    %% assertion
    % true = iolist_size(DataAndTrailer) == (DataSize + TrailerSize),
    write_chunk(Chunk, ChType, Timestamp, Epoch, NumRecords, State0);
accept_chunk(Binary, State) when is_binary(Binary) ->
    accept_chunk([Binary], State);
accept_chunk([<<?MAGIC:4/unsigned,
                ?VERSION:4/unsigned,
                _ChType:8/unsigned,
                _NumEntries:16/unsigned,
                _NumRecords:32/unsigned,
                _Timestamp:64/signed,
                _Epoch:64/unsigned,
                Next:64/unsigned,
                _Crc:32/integer,
                _/binary>>
              | _] =
                 _Chunk,
             #?MODULE{cfg = #cfg{},
                      mode = #write{tail_info = {ExpectedNext, _}}}) ->
    exit({accept_chunk_out_of_order, Next, ExpectedNext}).

-spec next_offset(state()) -> offset().
next_offset(#?MODULE{mode = #write{tail_info = {Next, _}}}) ->
    Next;
next_offset(#?MODULE{mode = #read{next_offset = Next}}) ->
    Next.

-spec first_offset(state()) -> offset().
first_offset(#?MODULE{cfg = #cfg{counter = Cnt}}) ->
    counters:get(Cnt, ?C_FIRST_OFFSET).

-spec first_timestamp(state()) -> osiris:timestamp().
first_timestamp(#?MODULE{cfg = #cfg{counter = Cnt}}) ->
    counters:get(Cnt, ?C_FIRST_TIMESTAMP).

-spec tail_info(state()) -> osiris:tail_info().
tail_info(#?MODULE{mode = #write{tail_info = TailInfo}}) ->
    TailInfo.

%% called by the writer before every write to evalaute segment size
%% and write a tracking snapshot
-spec evaluate_tracking_snapshot(state(), osiris_tracking:state()) ->
    {state(), osiris_tracking:state()}.
evaluate_tracking_snapshot(#?MODULE{mode = #write{type = writer}} = State0, Trk0) ->
    IsEmpty = osiris_tracking:is_empty(Trk0),
    case max_segment_size_reached(State0) of
        true when not IsEmpty ->
            State1 = State0,
            %% write a new tracking snapshot
            Now = erlang:system_time(millisecond),
            FstOffs = first_offset(State1),
            FstTs = first_timestamp(State1),
            {SnapBin, Trk1} = osiris_tracking:snapshot(FstOffs, FstTs, Trk0),
            {write([SnapBin],
                   ?CHNK_TRK_SNAPSHOT,
                   Now,
                   <<>>,
                   State1), Trk1};
        _ ->
            {State0, Trk0}
    end.

% -spec
-spec init_acceptor(range(), list(), config()) ->
    state().
init_acceptor(Range, EpochOffsets0,
              #{name := Name, dir := Dir} = Conf) ->
    %% truncate to first common last epoch offset
    %% * if the last local chunk offset has the same epoch but is lower
    %% than the last chunk offset then just attach at next offset.
    %% * if it is higher - truncate to last epoch offset
    %% * if it has a higher epoch than last provided - truncate to last offset
    %% of previous
    %% sort them so that the highest epochs go first
    EpochOffsets =
        lists:reverse(
            lists:sort(EpochOffsets0)),

    %% then truncate to
    IdxFiles = sorted_index_files(Dir),
    ?DEBUG("~s: ~s ~s from epoch offsets: ~w range ~w",
           [?MODULE, ?FUNCTION_NAME, Name, EpochOffsets, Range]),
    RemIdxFiles = truncate_to(Name, Range, EpochOffsets, IdxFiles),
    %% after truncation we can do normal init
    InitOffset = case Range  of
                     empty -> 0;
                     {O, _} -> O
                 end,
    init(Conf#{initial_offset => InitOffset,
               index_files => RemIdxFiles}, acceptor).

chunk_id_index_scan(IdxFile, ChunkId)
  when ?IS_STRING(IdxFile) ->
    Fd = open_index_read(IdxFile),
    chunk_id_index_scan0(Fd, ChunkId).

chunk_id_index_scan0(Fd, ChunkId) ->
    case file:read(Fd, ?INDEX_RECORD_SIZE_B) of
        {ok,
         <<ChunkId:64/unsigned,
           _Timestamp:64/signed,
           Epoch:64/unsigned,
           FilePos:32/unsigned,
           _ChType:8/unsigned>>} ->
	    {ok, IdxPos} = file:position(Fd, cur),
            ok = file:close(Fd),
            {ChunkId, Epoch, FilePos, IdxPos - ?INDEX_RECORD_SIZE_B};
        {ok, _} ->
            chunk_id_index_scan0(Fd, ChunkId);
        eof ->
            ok = file:close(Fd),
            eof
    end.

delete_segment_from_index(Index) ->
    File = segment_from_index_file(Index),
    ?DEBUG("osiris_log: deleting segment ~s", [File]),
    ok = prim_file:delete(Index),
    ok = prim_file:delete(File),
    ok.

truncate_to(_Name, _Range, _EpochOffsets, []) ->
    %% the target log is empty
    [];
truncate_to(_Name, _Range, [], IdxFiles) ->
    %% ?????  this means the entire log is out
    [begin ok = delete_segment_from_index(I) end || I <- IdxFiles],
    [];
truncate_to(Name, RemoteRange, [{E, ChId} | NextEOs], IdxFiles) ->
    case find_segment_for_offset(ChId, IdxFiles) of
        not_found ->
            case build_seg_info(lists:last(IdxFiles)) of
                {ok, #seg_info{last = #chunk_info{epoch = E,
                                                  id = LastChId,
                                                  num = Num}}}
                when ChId > LastChId + Num ->
                    %% the last available local chunk id is smaller than the
                    %% sources last chunk id but is in the same epoch
                    %% check if there is any overlap
                    LastOffsLocal = LastChId + Num,
                    FstOffsetRemote = case RemoteRange of
                                          empty -> 0;
                                          {F, _} -> F
                                      end,
                    case LastOffsLocal < FstOffsetRemote of
                        true ->
                            %% there is no overlap, need to delete all
                            %% local segments
                            [begin ok = delete_segment_from_index(I) end
                             || I <- IdxFiles],
                            [];
                        false ->
                            %% there is overlap
                            %% no truncation needed
                            IdxFiles
                    end;
                {ok, _} ->
                    truncate_to(Name, RemoteRange, NextEOs, IdxFiles)
                    %% TODO: what to do if error is returned from
                    %% build_seg_info/1?
            end;
        {end_of_log, _Info} ->
            IdxFiles;
        {found, #seg_info{file = File, index = IdxFile}} ->
            ?DEBUG("osiris_log: ~s on node ~s truncating to chunk "
                   "id ~b in epoch ~b",
                   [Name, node(), ChId, E]),
            %% this is the inclusive case
            %% next offset needs to be a chunk offset
            %% if it is not found we know the offset requested isn't a chunk
            %% id and thus isn't valid
            case chunk_id_index_scan(IdxFile, ChId) of
                {ChId, E, Pos, IdxPos} when is_integer(Pos) ->
                    %% the  Chunk id was found and has the right epoch
                    %% lets truncate to this point
                    %% FilePos could be eof here which means the next offset
                    {ok, Fd} = file:open(File, [read, write, binary, raw]),
                    _ = file:advise(Fd, 0, 0, random),
                    {ok, IdxFd} = file:open(IdxFile, [read, write, binary, raw]),

                    {_ChType, ChId, E, _Num, Size, TSize} = header_info(Fd, Pos),
                    %% position at end of chunk
                    {ok, _Pos} = file:position(Fd, {cur, Size + TSize}),
                    ok = file:truncate(Fd),

                    {ok, _} = file:position(IdxFd, IdxPos + ?INDEX_RECORD_SIZE_B),
                    ok = file:truncate(IdxFd),
                    ok = file:close(Fd),
                    ok = file:close(IdxFd),
                    %% delete all segments with a first offset larger then ChId
                    %% and return the remainder
                    lists:filter(
                      fun (I) ->
                              case index_file_first_offset(I) > ChId of
                                  true ->
                                      ok = delete_segment_from_index(I),
                                      false;
                                  false ->
                                      true
                              end
                      end, IdxFiles);
                _ ->
                    truncate_to(Name, RemoteRange, NextEOs, IdxFiles)
            end
    end.

-spec init_data_reader(osiris:tail_info(), config()) ->
                          {ok, state()} |
                          {error,
                           {offset_out_of_range,
                            empty | {offset(), offset()}}} |
                          {error,
                           {invalid_last_offset_epoch, epoch(), offset()}}.
init_data_reader({StartChunkId, PrevEOT}, #{dir := Dir,
                                            name := Name} = Config) ->
    IdxFiles = sorted_index_files(Dir),
    Range = offset_range_from_idx_files(IdxFiles),
    ?DEBUG("osiris_segment:init_data_reader/2 ~s at ~b prev "
           "~w local range: ~w",
           [Name, StartChunkId, PrevEOT, Range]),
    %% Invariant:  there is always at least one segment left on disk
    case Range of
        {FstOffs, LastOffs}
          when StartChunkId < FstOffs
               orelse StartChunkId > LastOffs + 1 ->
            {error, {offset_out_of_range, Range}};
        empty when StartChunkId > 0 ->
            {error, {offset_out_of_range, Range}};
        _ when PrevEOT == empty ->
            %% this assumes the offset is in range
            %% first we need to validate PrevEO
            {ok, init_data_reader_from(
                   StartChunkId,
                   find_segment_for_offset(StartChunkId, IdxFiles),
                   Config)};
        _ ->
            {PrevEpoch, PrevChunkId, _PrevTs} = PrevEOT,
            case check_chunk_has_expected_epoch(PrevChunkId, PrevEpoch, IdxFiles) of
                ok ->
                    {ok, init_data_reader_from(
                           StartChunkId,
                           find_segment_for_offset(StartChunkId, IdxFiles),
                           Config)};
                {error, _} = Err ->
                    Err
            end
    end.

check_chunk_has_expected_epoch(ChunkId, Epoch, IdxFiles) ->
    case find_segment_for_offset(ChunkId, IdxFiles) of
        not_found ->
            %% this is unexpected and thus an error
            {error,
             {invalid_last_offset_epoch, Epoch, unknown}};
        {found, #seg_info{} = SegmentInfo} ->
            %% prev segment exists, does it have the correct
            %% epoch?
            case offset_idx_scan(ChunkId, SegmentInfo) of
                {ChunkId, Epoch, _PrevPos} ->
                    ok;
                {ChunkId, OtherEpoch, _} ->
                    {error,
                     {invalid_last_offset_epoch, Epoch, OtherEpoch}}
            end
    end.

init_data_reader_at(ChunkId, FilePos, File,
                    #{dir := Dir, name := Name,
                      shared := Shared,
                      readers_counter_fun := CountersFun} = Config) ->
    {ok, Fd} = file:open(File, [raw, binary, read]),
    {ok, FilePos} = file:position(Fd, FilePos),
    Cnt = make_counter(Config),
    counters:put(Cnt, ?C_OFFSET, ChunkId - 1),
    CountersFun(1),
    #?MODULE{cfg =
                 #cfg{directory = Dir,
                      counter = Cnt,
                      counter_id = counter_id(Config),
                      name = Name,
                      readers_counter_fun = CountersFun,
                      shared = Shared
                     },
             mode =
                 #read{type = data,
                       next_offset = ChunkId,
                       chunk_selector = all,
                       transport = maps:get(transport, Config, tcp)},
             fd = Fd}.

init_data_reader_from(ChunkId,
                      {end_of_log, #seg_info{file = File,
                                             last = LastChunk}},
                      Config) ->
    {ChunkId, AttachPos} = next_location(LastChunk),
    init_data_reader_at(ChunkId, AttachPos, File, Config);
init_data_reader_from(ChunkId,
                      {found, #seg_info{file = File} = SegInfo},
                      Config) ->
    {ChunkId, _Epoch, FilePos} = offset_idx_scan(ChunkId, SegInfo),
    init_data_reader_at(ChunkId, FilePos, File, Config).

%% @doc Initialise a new offset reader
%% @param OffsetSpec specifies where in the log to attach the reader
%% `first': Attach at first available offset.
%% `last': Attach at the last available chunk offset or the next available offset
%% if the log is empty.
%% `next': Attach to the next chunk offset to be written.
%% `{abs, offset()}': Attach at the provided offset. If this offset does not exist
%% in the log it will error with `{error, {offset_out_of_range, Range}}'
%% `offset()': Like `{abs, offset()}' but instead of erroring it will fall back
%% to `first' (if lower than first offset in log) or `nextl if higher than
%% last offset in log.
%% @param Config The configuration. Requires the `dir' key.
%% @returns `{ok, state()} | {error, Error}' when error can be
%% `{offset_out_of_range, empty | {From :: offset(), To :: offset()}}'
%% @end
-spec init_offset_reader(OffsetSpec :: offset_spec(),
                         Config :: config()) ->
                            {ok, state()} |
                            {error,
                             {offset_out_of_range,
                              empty | {From :: offset(), To :: offset()}}} |
                            {error, {invalid_chunk_header, term()}} |
                            {error, no_index_file} |
                            {error, retries_exhausted}.
init_offset_reader(OffsetSpec, Conf) ->
    init_offset_reader(OffsetSpec, Conf, 3).

init_offset_reader(_OffsetSpec, _Conf, 0) ->
    {error, retries_exhausted};
init_offset_reader(OffsetSpec, Conf, Attempt) ->
    try
        init_offset_reader0(OffsetSpec, Conf)
    catch
        missing_file ->
            %% Retention policies are likely being applied, let's try again
            %% TODO: should we limit the number of retries?
            %% Remove cached index_files from config
            init_offset_reader(OffsetSpec,
                               maps:remove(index_files, Conf), Attempt - 1);
        {retry_with, NewOffsSpec, NewConf} ->
            init_offset_reader(NewOffsSpec, NewConf, Attempt - 1)
    end.

init_offset_reader0({abs, Offs}, #{dir := Dir} = Conf) ->
    case sorted_index_files(Dir) of
        [] ->
            {error, no_index_file};
        IdxFiles ->
            Range = offset_range_from_idx_files(IdxFiles),
            case Range of
                empty ->
                    {error, {offset_out_of_range, Range}};
                {S, E} when Offs < S orelse Offs > E ->
                    {error, {offset_out_of_range, Range}};
                _ ->
                    %% it is in range, convert to standard offset
                    init_offset_reader0(Offs, Conf)
            end
    end;
init_offset_reader0({timestamp, Ts}, #{} = Conf) ->
    case sorted_index_files_rev(Conf) of
        [] ->
            init_offset_reader0(next, Conf);
        IdxFilesRev ->
            case timestamp_idx_file_search(Ts, IdxFilesRev) of
                {scan, IdxFile} ->
                    %% segment was found, now we need to scan index to
                    %% find nearest offset
                    {ChunkId, FilePos} = chunk_location_for_timestamp(IdxFile, Ts),
                    SegmentFile = segment_from_index_file(IdxFile),
                    open_offset_reader_at(SegmentFile, ChunkId, FilePos, Conf);
                {first_in, IdxFile} ->
                    {ok, Fd} = file:open(IdxFile, [raw, binary, read]),
                    {ok, <<ChunkId:64/unsigned,
                           _Ts:64/signed,
                           _:64/unsigned,
                           FilePos:32/unsigned,
                           _:8/unsigned>>} = first_idx_record(Fd),
                    SegmentFile = segment_from_index_file(IdxFile),
                    open_offset_reader_at(SegmentFile, ChunkId, FilePos, Conf);
                next ->
                    %% segment was not found, attach next
                    %% this should be rare so no need to call the more optimal
                    %% open_offset_reader_at/4 function
                    init_offset_reader0(next, Conf)
            end
    end;
init_offset_reader0(first, #{} = Conf) ->
    case sorted_index_files(Conf) of
        [] ->
            {error, no_index_file};
        [FstIdxFile | _ ] ->
            case build_seg_info(FstIdxFile) of
                {ok, #seg_info{file = File,
                               first = undefined}} ->
                    %% empty log, attach at 0
                    open_offset_reader_at(File, 0, ?LOG_HEADER_SIZE, Conf);
                {ok, #seg_info{file = File,
                               first = #chunk_info{id = FirstChunkId,
                                                   pos = FilePos}}} ->
                    open_offset_reader_at(File, FirstChunkId, FilePos, Conf);
                {error, _} = Err ->
                    exit(Err)
            end
    end;
init_offset_reader0(next, #{} = Conf) ->
    case sorted_index_files_rev(Conf) of
        [] ->
            {error, no_index_file};
        [LastIdxFile | _ ] ->
            case build_seg_info(LastIdxFile) of
                {ok, #seg_info{file = File,
                               last = LastChunk}} ->
                    {NextChunkId, FilePos} = next_location(LastChunk),
                    open_offset_reader_at(File, NextChunkId, FilePos, Conf);
                Err ->
                    exit(Err)
            end
    end;
init_offset_reader0(last, #{} = Conf) ->
    case sorted_index_files_rev(Conf) of
        [] ->
            {error, no_index_file};
        IdxFiles ->
            case last_user_chunk_location(IdxFiles) of
                not_found ->
                    ?DEBUG("~s:~s user chunk not found, fall back to next",
                           [?MODULE, ?FUNCTION_NAME]),
                    %% no user chunks in stream, this is awkward, fall back to next
                    init_offset_reader0(next, Conf);
                {ChunkId, FilePos, IdxFile} ->
                    File = segment_from_index_file(IdxFile),
                    open_offset_reader_at(File, ChunkId, FilePos, Conf)
            end
    end;
init_offset_reader0(OffsetSpec, #{} = Conf)
  when is_integer(OffsetSpec) ->
    case sorted_index_files(Conf) of
        [] ->
            {error, no_index_file};
        IdxFiles ->
            Range = offset_range_from_idx_files(IdxFiles),
            ?DEBUG("osiris_log:init_offset_reader0/2 spec ~w range ~w ",
                   [OffsetSpec, Range]),
            %% clamp start offset
            StartOffset = case {OffsetSpec, Range} of
                              {_, empty} ->
                                  0;
                              {Offset, {_, LastOffs}}
                                when Offset == LastOffs + 1 ->
                                  %% next but we can't use `next`
                                  %% due to race conditions
                                  Offset;
                              {Offset, {_, LastOffs}}
                                when Offset > LastOffs + 1 ->
                                  %% out of range, clamp as `next`
                                  throw({retry_with, next, Conf});
                              {Offset, {FirstOffs, _LastOffs}} ->
                                  max(FirstOffs, Offset)
                          end,

            case find_segment_for_offset(StartOffset, IdxFiles) of
                not_found ->
                    {error, {offset_out_of_range, Range}};
                {end_of_log, #seg_info{file = SegmentFile,
                                       last = LastChunk}} ->
                    {ChunkId, FilePos} = next_location(LastChunk),
                    open_offset_reader_at(SegmentFile, ChunkId, FilePos, Conf);
                {found, #seg_info{file = SegmentFile} = SegmentInfo} ->
                    {ChunkId, _Epoch, FilePos} =
                        case offset_idx_scan(StartOffset, SegmentInfo) of
                            eof ->
                                exit(offset_out_of_range);
                            enoent ->
                                %% index file was not found
                                %% throw should be caught and trigger a retry
                                throw(missing_file);
                            offset_out_of_range ->
                                exit(offset_out_of_range);
                            IdxResult when is_tuple(IdxResult) ->
                                IdxResult
                        end,
                    ?DEBUG("osiris_log:init_offset_reader0/2 resolved chunk_id ~b"
                           " at file pos: ~w ", [ChunkId, FilePos]),
                    open_offset_reader_at(SegmentFile, ChunkId, FilePos, Conf)
            end
    end.

open_offset_reader_at(SegmentFile, NextChunkId, FilePos,
                      #{dir := Dir,
                        name := Name,
                        shared := Shared,
                        readers_counter_fun := ReaderCounterFun,
                        options := Options} =
                      Conf) ->
    {ok, Fd} = open(SegmentFile, [raw, binary, read]),
    {ok, FilePos} = file:position(Fd, FilePos),
    Cnt = make_counter(Conf),
    ReaderCounterFun(1),
    {ok, #?MODULE{cfg = #cfg{directory = Dir,
                             counter = Cnt,
                             counter_id = counter_id(Conf),
                             name = Name,
                             readers_counter_fun = ReaderCounterFun,
                             shared = Shared
                            },
                  mode = #read{type = offset,
                               chunk_selector = maps:get(chunk_selector, Options,
                                                         user_data),
                               next_offset = NextChunkId,
                               transport = maps:get(transport, Options, tcp)},
                  fd = Fd}}.

%% Searches the index files backwards for the ID of the last user chunk.
last_user_chunk_location(RevdIdxFiles)
  when is_list(RevdIdxFiles) ->
    {Time, Result} = timer:tc(
                       fun() ->
                               last_user_chunk_id0(RevdIdxFiles)
                       end),
    ?DEBUG("~s:~s/~b completed in ~fs", [?MODULE, ?FUNCTION_NAME, ?FUNCTION_ARITY, Time/1_000_000]),
    Result.

last_user_chunk_id0([]) ->
    %% There are no user chunks in any index files.
    not_found;
last_user_chunk_id0([IdxFile | Rest]) ->
    %% Do not read-ahead since we read the index file backwards chunk by chunk.
    {ok, IdxFd} = open(IdxFile, [read, raw, binary]),
    {ok, EofPos} = position_at_idx_record_boundary(IdxFd, eof),
    Last = last_user_chunk_id_in_index(EofPos - ?INDEX_RECORD_SIZE_B, IdxFd),
    _ = file:close(IdxFd),
    case Last of
        {ok, Id, Pos} ->
            {Id, Pos, IdxFile};
        {error, Reason} ->
            ?DEBUG("Could not find user chunk in index file ~s (~p)", [IdxFile, Reason]),
            last_user_chunk_id0(Rest)
    end.

%% Searches the index file backwards for the ID of the last user chunk.
last_user_chunk_id_in_index(NextPos, IdxFd) ->
    case file:pread(IdxFd, NextPos, ?INDEX_RECORD_SIZE_B) of
        {ok, <<Offset:64/unsigned,
               _Timestamp:64/signed,
               _Epoch:64/unsigned,
               FilePos:32/unsigned,
               ?CHNK_USER:8/unsigned>>} ->
            {ok, Offset, FilePos};
        {ok, <<_Offset:64/unsigned,
               _Timestamp:64/signed,
               _Epoch:64/unsigned,
               _FilePos:32/unsigned,
               _ChType:8/unsigned>>} ->
            last_user_chunk_id_in_index(NextPos - ?INDEX_RECORD_SIZE_B, IdxFd);
        {error, _} = Error ->
            Error
    end.

-spec committed_offset(state()) -> integer().
committed_offset(#?MODULE{cfg = #cfg{shared = Ref}}) ->
    osiris_log_shared:committed_chunk_id(Ref).

-spec set_committed_chunk_id(state(), offset()) -> ok.
set_committed_chunk_id(#?MODULE{mode = #write{},
                                cfg = #cfg{shared = Ref}}, ChunkId)
  when is_integer(ChunkId) ->
    osiris_log_shared:set_committed_chunk_id(Ref, ChunkId).

-spec get_current_epoch(state()) -> non_neg_integer().
get_current_epoch(#?MODULE{mode = #write{current_epoch = Epoch}}) ->
    Epoch.

-spec get_directory(state()) -> file:filename_all().
get_directory(#?MODULE{cfg = #cfg{directory = Dir}}) ->
    Dir.

-spec get_name(state()) -> string().
get_name(#?MODULE{cfg = #cfg{name = Name}}) ->
    Name.

-spec get_shared(state()) -> atomics:atomics_ref().
get_shared(#?MODULE{cfg = #cfg{shared = Shared}}) ->
    Shared.

-spec get_default_max_segment_size_bytes() -> non_neg_integer().
get_default_max_segment_size_bytes() ->
    ?DEFAULT_MAX_SEGMENT_SIZE_B.

-spec counters_ref(state()) -> counters:counters_ref().
counters_ref(#?MODULE{cfg = #cfg{counter = C}}) ->
    C.

-spec read_header(state()) ->
    {ok, header_map(), state()} | {end_of_stream, state()} |
    {error, {invalid_chunk_header, term()}}.
read_header(#?MODULE{cfg = #cfg{}} = State0) ->
    %% reads the next chunk of entries, parsed
    %% NB: this may return records before the requested index,
    %% that is fine - the reading process can do the appropriate filtering
    %% TODO: skip non user chunks for offset readers
    case read_header0(State0) of
        {ok,
         #{num_records := NumRecords,
           data_size := DataSize,
           trailer_size := TrailerSize} =
             Header,
         #?MODULE{mode = #read{} = Read, fd = Fd} = State} ->
            %% skip data portion
            {ok, _} = file:position(Fd, {cur, DataSize + TrailerSize}),
            {ok, Header,
             State#?MODULE{mode = incr_next_offset(NumRecords, Read)}};
        {end_of_stream, _} = EOF ->
            EOF;
        {error, _} = Err ->
            Err
    end.

-spec read_chunk(state()) ->
                    {ok,
                     {chunk_type(),
                      offset(),
                      epoch(),
                      HeaderData :: iodata(),
                      RecordData :: iodata(),
                      TrailerData :: iodata()},
                     state()} |
                    {end_of_stream, state()} |
                    {error, {invalid_chunk_header, term()}}.
read_chunk(#?MODULE{cfg = #cfg{}} = State0) ->
    %% reads the next chunk of entries, parsed
    %% NB: this may return records before the requested index,
    %% that is fine - the reading process can do the appropriate filtering
    case read_header0(State0) of
        {ok,
         #{type := ChType,
           chunk_id := ChId,
           epoch := Epoch,
           crc := Crc,
           num_records := NumRecords,
           header_data := HeaderData,
           data_size := DataSize,
           trailer_size := TrailerSize},
         #?MODULE{fd = Fd, mode = #read{next_offset = ChId} = Read} = State} ->
            {ok, BlobData} = file:read(Fd, DataSize),
            {ok, TrailerData} = file:read(Fd, TrailerSize),
            validate_crc(ChId, Crc, BlobData),
            {ok, {ChType, ChId, Epoch, HeaderData, BlobData, TrailerData},
             State#?MODULE{mode = incr_next_offset(NumRecords, Read)}};
        Other ->
            Other
    end.

-spec read_chunk_parsed(state()) ->
                           {[record()], state()} |
                           {end_of_stream, state()} |
                           {error, {invalid_chunk_header, term()}}.
read_chunk_parsed(State) ->
    read_chunk_parsed(State, no_header).

-spec read_chunk_parsed(state(), no_header | with_header) ->
    {[record()], state()} |
    {ok, header_map(), [record()], state()} |
    {end_of_stream, state()} |
    {error, {invalid_chunk_header, term()}}.
read_chunk_parsed(#?MODULE{mode = #read{type = RType,
                                        chunk_selector = Selector}} = State0,
                 HeaderOrNot) ->
    %% reads the next chunk of entries, parsed
    %% NB: this may return records before the requested index,
    %% that is fine - the reading process can do the appropriate filtering
    case read_header0(State0) of
        {ok,
         #{type := ChType,
           chunk_id := ChId,
           crc := Crc,
           num_records := NumRecords,
           data_size := DataSize,
           trailer_size := TrailerSize} = Header,
         #?MODULE{fd = Fd, mode = #read{next_offset = _ChId} = Read} = State1} ->
            {ok, Data} = file:read(Fd, DataSize),
            {ok, _TrailerData} = file:read(Fd, TrailerSize),
            validate_crc(ChId, Crc, Data),
            State = State1#?MODULE{mode = incr_next_offset(NumRecords, Read)},
            case needs_handling(RType, Selector, ChType) of
                true when HeaderOrNot == no_header ->
                    %% parse data into records
                    {parse_records(ChId, Data, []), State};
                true ->
                    {ok, Header, parse_records(ChId, Data, []), State};
                false ->
                    %% skip
                    read_chunk_parsed(State, HeaderOrNot)
            end;
        Ret ->
            Ret
    end.

is_valid_chunk_on_disk(SegFile, Pos) ->
    %% read a chunk from a specified location in the segment
    %% then checks the CRC
    case open(SegFile, [read, raw, binary]) of
        {ok, SegFd} ->
            {ok, Pos} = file:position(SegFd, Pos),
            IsValid = case file:read(SegFd, ?HEADER_SIZE_B) of
                          {ok,
                           <<?MAGIC:4/unsigned,
                             ?VERSION:4/unsigned,
                             _ChType:8/unsigned,
                             _NumEntries:16/unsigned,
                             _NumRecords:32/unsigned,
                             _Timestamp:64/signed,
                             _Epoch:64/unsigned,
                             _NextChId0:64/unsigned,
                             Crc:32/integer,
                             DataSize:32/unsigned,
                             _TrailerSize:32/unsigned,
                             _Reserved:32>>} ->
                              {ok, Data} = file:read(SegFd, DataSize),
                              case erlang:crc32(Data) of
                                  Crc ->
                                      true;
                                  _ ->
                                      false
                              end;
                          _ ->
                              false
                      end,
            _ = file:close(SegFd),
            IsValid;
       _Err ->
            false
    end.


-spec send_file(gen_tcp:socket(), state()) ->
                   {ok, state()} |
                   {error, term()} |
                   {end_of_stream, state()}.
send_file(Sock, State) ->
    send_file(Sock, State, fun(_, _) -> ok end).

-spec send_file(gen_tcp:socket(), state(),
                fun((header_map(), non_neg_integer()) -> term())) ->
                   {ok, state()} |
                   {error, term()} |
                   {end_of_stream, state()}.
send_file(Sock,
          #?MODULE{cfg = #cfg{}, mode = #read{type = RType,
                                              chunk_selector = Selector,
                                              transport = Transport}} = State0,
          Callback) ->
    case read_header0(State0) of
        {ok,
         #{type := ChType,
           chunk_id := ChId,
           num_records := NumRecords,
           data_size := DataSize,
           trailer_size := TrailerSize,
           position := Pos} = Header,
         #?MODULE{fd = Fd, mode = #read{next_offset = ChId} = Read} = State1} ->
            %% read header
            %% used to write frame headers to socket
            %% and return the number of bytes to sendfile
            %% this allow users of this api to send all the data
            %% or just header and entry data
            ToSend = case RType of
                         offset ->
                             select_chunk_to_send(Selector, ChType, DataSize, TrailerSize);
                         data ->
                             DataSize + TrailerSize + ?HEADER_SIZE_B
                     end,

            %% sendfile doesn't increment the file descriptor position
            %% so we have to do this manually
            NextFilePos = Pos + DataSize + TrailerSize + ?HEADER_SIZE_B,
            State = State1#?MODULE{mode = incr_next_offset(NumRecords, Read)},
            %% only sendfile if either the reader is a data reader
            %% or the chunk is a user type (for offset readers)
            case needs_handling(RType, Selector, ChType) of
                true ->
                    %% this avoids any data sent in the Callback to be dispatched
                    %% in it's own TCP frame
                    ok = setopts(Transport, Sock, [{nopush, true}]),
                    _ = Callback(Header, ToSend),
                    case sendfile(Transport, Fd, Sock, Pos, ToSend) of
                        ok ->
                            ok = setopts(Transport, Sock, [{nopush, false}]),
                            {ok, _} = file:position(Fd, NextFilePos),
                            {ok, State};
                        Err ->
                            %% reset the position to the start of the current
                            %% chunk so that subsequent reads won't error
                            {ok, _} = file:position(Fd, Pos),
                            Err
                    end;
                false ->
                    {ok, _} = file:position(Fd, NextFilePos),
                    %% skip chunk and recurse
                    send_file(Sock, State, Callback)
            end;
        Other ->
            Other
    end.

%% There could be many more selectors in the future
select_chunk_to_send(user_data, ?CHNK_USER, DataSize, _TrailerSize) ->
    DataSize + ?HEADER_SIZE_B;
select_chunk_to_send(_, _, DataSize, TrailerSize) ->
    DataSize + TrailerSize + ?HEADER_SIZE_B.

needs_handling(data, _, _) ->
    true;
needs_handling(offset, all, _ChType) ->
    true;
needs_handling(offset, user_data, ?CHNK_USER) ->
    true;
needs_handling(_, _, _) ->
    false.

-spec close(state()) -> ok.
close(#?MODULE{cfg = #cfg{counter_id = CntId,
                          readers_counter_fun = Fun},
               fd = SegFd,
               index_fd = IdxFd}) ->
    close_fd(IdxFd),
    close_fd(SegFd),
    Fun(-1),
    case CntId of
        undefined ->
            ok;
        _ ->
            osiris_counters:delete(CntId)
    end.

delete_directory(#{name := Name} = Config) when is_map(Config) ->
    delete_directory(Name);
delete_directory(Name) when ?IS_STRING(Name) ->
    Dir = directory(Name),
    ?DEBUG("osiris_log: deleting directory ~s", [Dir]),
    case file:list_dir(Dir) of
        {ok, Files} ->
            [ok =
                 file:delete(
                     filename:join(Dir, F))
             || F <- Files],
            ok = file:del_dir(Dir);
        {error, enoent} ->
            ok
    end.

%% Internal

header_info(Fd, Pos) ->
    {ok, Pos} = file:position(Fd, Pos),
    {ok,
     <<?MAGIC:4/unsigned,
       ?VERSION:4/unsigned,
       ChType:8/unsigned,
       _NumEntries:16/unsigned,
       Num:32/unsigned,
       _Timestamp:64/signed,
       Epoch:64/unsigned,
       Offset:64/unsigned,
       _Crc:32/integer,
       Size:32/unsigned,
       TSize:32/unsigned,
       _Reserved:32>>} =
        file:read(Fd, ?HEADER_SIZE_B),
    {ChType, Offset, Epoch, Num, Size, TSize}.

parse_records(_Offs, <<>>, Acc) ->
    %% TODO: this could probably be changed to body recursive
    lists:reverse(Acc);
parse_records(Offs,
              <<0:1, %% simple
                Len:31/unsigned,
                Data:Len/binary,
                Rem/binary>>,
              Acc) ->
    parse_records(Offs + 1, Rem, [{Offs, Data} | Acc]);
parse_records(Offs,
              <<1:1, %% simple
                0:3/unsigned, %% compression type
                _:4/unsigned, %% reserved
                NumRecs:16/unsigned,
                _UncompressedLen:32/unsigned,
                Len:32/unsigned,
                Data:Len/binary,
                Rem/binary>>,
              Acc) ->
    Recs = parse_records(Offs, Data, []),
    parse_records(Offs + NumRecs, Rem, lists:reverse(Recs) ++ Acc);
parse_records(Offs,
              <<1:1, %% simple
                CompType:3/unsigned, %% compression type
                _:4/unsigned, %% reserved
                NumRecs:16/unsigned,
                UncompressedLen:32/unsigned,
                Len:32/unsigned,
                Data:Len/binary,
                Rem/binary>>,
              Acc) ->
    %% return the first offset of the sub batch and the batch, unparsed
    %% as we don't want to decompress on the server
    parse_records(Offs + NumRecs, Rem,
                  [{Offs, {batch, NumRecs, CompType, UncompressedLen, Data}} | Acc]).

sorted_index_files(#{index_files := IdxFiles}) ->
    %% cached
    IdxFiles;
sorted_index_files(#{dir := Dir}) ->
    sorted_index_files(Dir);
sorted_index_files(Dir) when ?IS_STRING(Dir) ->
    Files = index_files_unsorted(Dir),
    lists:sort(Files).

sorted_index_files_rev(#{index_files := IdxFiles}) ->
    %% cached
    lists:reverse(IdxFiles);
sorted_index_files_rev(#{dir := Dir}) ->
    sorted_index_files_rev(Dir);
sorted_index_files_rev(Dir) ->
    Files = index_files_unsorted(Dir),
    lists:sort(fun erlang:'>'/2, Files).

index_files_unsorted(Dir) ->
    case prim_file:list_dir(Dir) of
        {error, enoent} ->
            [];
        {ok, Files} ->
            [filename:join(Dir, F)
             || F <- Files,
                filename:extension(F) == ".index" orelse
                filename:extension(F) == <<".index">>]
    end.

first_and_last_seginfos(#{index_files := IdxFiles}) ->
    first_and_last_seginfos0(IdxFiles);
first_and_last_seginfos(#{dir := Dir}) ->
    first_and_last_seginfos0(sorted_index_files(Dir)).

first_and_last_seginfos0([]) ->
    none;
first_and_last_seginfos0([FstIdxFile]) ->
    %% this function is only used by init
    {ok, SegInfo} = build_seg_info(FstIdxFile),
    {1, SegInfo, SegInfo};
first_and_last_seginfos0([FstIdxFile | Rem] = IdxFiles) ->
    %% this function is only used by init
    case build_seg_info(FstIdxFile) of
        {ok, FstSegInfo} ->
            LastIdxFile = lists:last(Rem),
            case build_seg_info(LastIdxFile) of
                {ok, #seg_info{first = undefined,
                               last = undefined}} ->
                    %% the last index file doesn't have any index records yet
                    %% retry without it
                    [_ | RetryIndexFiles] = lists:reverse(IdxFiles),
                    first_and_last_seginfos0(lists:reverse(RetryIndexFiles));
                {ok, LastSegInfo} ->
                    {length(Rem) + 1, FstSegInfo, LastSegInfo};
                {error, Err} ->
                    ?ERROR("~s: failed to build seg_info from file ~s, error: ~w",
                           [?MODULE, LastIdxFile, Err]),
                    error(Err)
            end;
        {error, enoent} ->
            %% most likely retention race condition
            first_and_last_seginfos0(Rem)
    end.

build_seg_info(IdxFile) ->
    case last_valid_idx_record(IdxFile) of
        {ok, <<_Offset:64/unsigned,
               _Timestamp:64/signed,
               _Epoch:64/unsigned,
               LastChunkPos:32/unsigned,
               _ChType:8/unsigned>>} ->
            SegFile = segment_from_index_file(IdxFile),
            build_segment_info(SegFile, LastChunkPos, IdxFile);
        undefined ->
            %% this would happen if the file only contained a header
            SegFile = segment_from_index_file(IdxFile),
            {ok, #seg_info{file = SegFile, index = IdxFile}};
        {error, _} = Err ->
            Err
    end.

last_idx_record(IdxFd) ->
    nth_last_idx_record(IdxFd, 1).

nth_last_idx_record(IdxFile, N) when ?IS_STRING(IdxFile) ->
    {ok, IdxFd} = open(IdxFile, [read, raw, binary]),
    IdxRecord = nth_last_idx_record(IdxFd, N),
    _ = file:close(IdxFd),
    IdxRecord;
nth_last_idx_record(IdxFd, N) ->
    case position_at_idx_record_boundary(IdxFd, {eof, -?INDEX_RECORD_SIZE_B * N}) of
        {ok, _} ->
            file:read(IdxFd, ?INDEX_RECORD_SIZE_B);
        Err ->
            Err
    end.

last_valid_idx_record(IdxFile) ->
    {ok, IdxFd} = open(IdxFile, [read, raw, binary]),
    case position_at_idx_record_boundary(IdxFd, eof) of
        {ok, Pos} ->
            SegFile = segment_from_index_file(IdxFile),
            SegSize = file_size(SegFile),
            ok = skip_invalid_idx_records(IdxFd, SegFile, SegSize, Pos),
            case file:position(IdxFd, {cur, -?INDEX_RECORD_SIZE_B}) of
                {ok, _} ->
                    IdxRecord = file:read(IdxFd, ?INDEX_RECORD_SIZE_B),
                    _ = file:close(IdxFd),
                    IdxRecord;
                _ ->
                    _ = file:close(IdxFd),
                    undefined
            end;
        Err ->
            _ = file:close(IdxFd),
            Err
    end.

first_idx_record(IdxFd) ->
    file:pread(IdxFd, ?IDX_HEADER_SIZE, ?INDEX_RECORD_SIZE_B).

%% Some file:position/2 operations are subject to race conditions. In particular, `eof` may position the Fd
%% in the middle of a record being written concurrently. If that happens, we need to re-position at the nearest
%% record boundry. See https://github.com/rabbitmq/osiris/issues/73
position_at_idx_record_boundary(IdxFd, At) ->
    case file:position(IdxFd, At) of
        {ok, Pos} ->
            case (Pos - ?IDX_HEADER_SIZE) rem ?INDEX_RECORD_SIZE_B of
                0 -> {ok, Pos};
                N -> file:position(IdxFd, {cur, -N})
            end;
        Error -> Error
    end.

build_segment_info(SegFile, LastChunkPos, IdxFile) ->
    {ok, Fd} = open(SegFile, [read, binary, raw]),
    %% we don't want to read blocks into page cache we are unlikely to need
    _ = file:advise(Fd, 0, 0, random),
    case file:pread(Fd, ?LOG_HEADER_SIZE, ?HEADER_SIZE_B) of
        eof ->
            _ = file:close(Fd),
            eof;
        {ok,
         <<?MAGIC:4/unsigned,
           ?VERSION:4/unsigned,
           FirstChType:8/unsigned,
           _NumEntries:16/unsigned,
           FirstNumRecords:32/unsigned,
           FirstTs:64/signed,
           FirstEpoch:64/unsigned,
           FirstChId:64/unsigned,
           _FirstCrc:32/integer,
           FirstSize:32/unsigned,
           FirstTSize:32/unsigned,
           _/binary>>} ->
            case file:pread(Fd, LastChunkPos, ?HEADER_SIZE_B) of
                {ok,
                 <<?MAGIC:4/unsigned,
                   ?VERSION:4/unsigned,
                   LastChType:8/unsigned,
                   _LastNumEntries:16/unsigned,
                   LastNumRecords:32/unsigned,
                   LastTs:64/signed,
                   LastEpoch:64/unsigned,
                   LastChId:64/unsigned,
                   _LastCrc:32/integer,
                   LastSize:32/unsigned,
                   LastTSize:32/unsigned,
                   _Reserved:32>>} ->
                    Size = LastChunkPos + LastSize + LastTSize + ?HEADER_SIZE_B,
                    {ok, Eof} = file:position(Fd, eof),
                    ?DEBUG_IF("~s: segment ~s has trailing data ~w ~w",
                              [?MODULE, filename:basename(SegFile),
                               Size, Eof], Size =/= Eof),
                    _ = file:close(Fd),
                    {ok, #seg_info{file = SegFile,
                                   index = IdxFile,
                                   size = Size,
                                   first =
                                   #chunk_info{epoch = FirstEpoch,
                                               timestamp = FirstTs,
                                               id = FirstChId,
                                               num = FirstNumRecords,
                                               type = FirstChType,
                                               size = FirstSize + FirstTSize,
                                               pos = ?LOG_HEADER_SIZE},
                                   last =
                                   #chunk_info{epoch = LastEpoch,
                                               timestamp = LastTs,
                                               id = LastChId,
                                               num = LastNumRecords,
                                               type = LastChType,
                                               size = LastSize + LastTSize,
                                               pos = LastChunkPos}}};
                _ ->
                    % last chunk is corrupted - try the previous one
                    _ = file:close(Fd),
                    {ok, <<_Offset:64/unsigned,
                           _Timestamp:64/signed,
                           _Epoch:64/unsigned,
                           PreviousChunkPos:32/unsigned,
                           _ChType:8/unsigned>>} = nth_last_idx_record(IdxFile, 2),
                    case PreviousChunkPos == LastChunkPos of
                        false ->
                            build_segment_info(SegFile, PreviousChunkPos, IdxFile);
                        true ->
                            % avoid an infinite loop if multiple chunks are corrupted
                            ?ERROR("Multiple corrupted chunks in segment file ~p", [SegFile]),
                            exit({corrupted_segment, {segment_file, SegFile}})
                    end
            end
    end.

-spec overview(term()) -> {range(), [{epoch(), offset()}]}.
overview(Dir) ->
    case sorted_index_files(Dir) of
        [] ->
            {empty, []};
        IdxFiles ->
            Range = offset_range_from_idx_files(IdxFiles),
            EpochOffsets = last_epoch_offsets(IdxFiles),
            {Range, EpochOffsets}
    end.

-spec format_status(state()) -> map().
format_status(#?MODULE{cfg = #cfg{directory = Dir,
                                  max_segment_size_bytes  = MSSB,
                                  max_segment_size_chunks  = MSSC,
                                  tracking_config = TrkConf,
                                  retention = Retention},
                       mode = Mode0,
                       current_file = File}) ->
    Mode = case Mode0 of
               #read{type = T,
                     next_offset = Next} ->
                   #{mode => read,
                     type => T,
                     next_offset => Next};
               #write{type = T,
                      current_epoch =E,
                      tail_info = Tail} ->
                   #{mode => write,
                     type => T,
                     tail => Tail,
                     epoch => E}
           end,

    #{mode => Mode,
      directory => Dir,
      max_segment_size_bytes  => MSSB,
      max_segment_size_chunks  => MSSC,
      tracking_config => TrkConf,
      retention => Retention,
      file => filename:basename(File)}.

-spec update_retention([retention_spec()], state()) -> state().
update_retention(Retention,
                 #?MODULE{cfg = #cfg{retention = Retention0} = Cfg} = State0)
    when is_list(Retention) ->
    ?DEBUG("osiris_log: update_retention from: ~w to ~w",
           [Retention0, Retention]),
    State = State0#?MODULE{cfg = Cfg#cfg{retention = Retention}},
    trigger_retention_eval(State).

-spec evaluate_retention(file:filename_all(), [retention_spec()]) ->
    {range(), FirstTimestamp :: osiris:timestamp(),
     NumRemainingFiles :: non_neg_integer()}.
evaluate_retention(Dir, Specs) when is_list(Dir) ->
    % convert to binary for faster operations later
    % mostly in segment_from_index_file/1
    evaluate_retention(list_to_binary(Dir), Specs);
evaluate_retention(Dir, Specs) when is_binary(Dir) ->

    {Time, Result} = timer:tc(
                       fun() ->
                               IdxFiles0 = sorted_index_files(Dir),
                               IdxFiles = evaluate_retention0(IdxFiles0, Specs),
                               OffsetRange = offset_range_from_idx_files(IdxFiles),
                               FirstTs = first_timestamp_from_index_files(IdxFiles),
                               {OffsetRange, FirstTs, length(IdxFiles)}
                       end),
    ?DEBUG("~s:~s/~b (~w) completed in ~fs",
           [?MODULE, ?FUNCTION_NAME, ?FUNCTION_ARITY, Specs, Time/1_000_000]),
    Result.

evaluate_retention0(IdxFiles, []) ->
    IdxFiles;
evaluate_retention0(IdxFiles, [{max_bytes, MaxSize} | Specs]) ->
    RemIdxFiles = eval_max_bytes(IdxFiles, MaxSize),
    evaluate_retention0(RemIdxFiles, Specs);
evaluate_retention0(IdxFiles, [{max_age, Age} | Specs]) ->
    RemIdxFiles = eval_age(IdxFiles, Age),
    evaluate_retention0(RemIdxFiles, Specs).

eval_age([_] = IdxFiles, _Age) ->
    IdxFiles;
eval_age([IdxFile | IdxFiles] = AllIdxFiles, Age) ->
    case last_timestamp_in_index_file(IdxFile) of
        {ok, Ts} ->
            Now = erlang:system_time(millisecond),
            case Ts < Now - Age of
                true ->
                    %% the oldest timestamp is older than retention
                    %% and there are other segments available
                    %% we can delete
                    ok = delete_segment_from_index(IdxFile),
                    eval_age(IdxFiles, Age);
                false ->
                    AllIdxFiles
            end;
        _Err ->
            AllIdxFiles
    end;
eval_age([], _Age) ->
    %% this could happen if retention is evaluated whilst
    %% a stream is being deleted
    [].

eval_max_bytes([], _) -> [];
eval_max_bytes(IdxFiles, MaxSize) ->
    [Latest|Older] = lists:reverse(IdxFiles),
    eval_max_bytes(Older,
                   %% for retention eval it is ok to use a file size function
                   %% that implicitly return 0 when file is not found
                   MaxSize - file_size_or_zero(
                               segment_from_index_file(Latest)),
                   [Latest]).

eval_max_bytes([], _, Acc) ->
    Acc;
eval_max_bytes([IdxFile | Rest], Limit, Acc) ->
    SegFile = segment_from_index_file(IdxFile),
    Size = file_size(SegFile),
    case Size =< Limit of
        true ->
            eval_max_bytes(Rest, Limit - Size, [IdxFile | Acc]);
        false ->
            [ok = delete_segment_from_index(Seg) || Seg <- [IdxFile | Rest]],
            Acc
    end.

file_size(Path) ->
    case prim_file:read_file_info(Path) of
        {ok, #file_info{size = Size}} ->
            Size;
        {error, enoent} ->
            throw(missing_file)
    end.

file_size_or_zero(Path) ->
    case prim_file:read_file_info(Path) of
        {ok, #file_info{size = Size}} ->
            Size;
        {error, enoent} ->
            0
    end.

last_epoch_offsets([IdxFile]) ->
    Fd = open_index_read(IdxFile),
    _ = file:advise(Fd, 0, 0, sequential),
    Record = file:read(Fd, ?INDEX_RECORD_SIZE_B),
    case last_epoch_offset(Record, Fd, undefined) of
        undefined ->
            [];
        {LastE, LastO, Res} ->
            lists:reverse([{LastE, LastO} | Res])
    end;
last_epoch_offsets([FstIdxFile | _]  = IdxFiles) ->
    F = fun() ->
                {ok, FstFd} = open(FstIdxFile, [read, raw, binary]),
		%% on linux this disables read-ahead so should only
		%% bring a single block into memory
		%% having the first block of index files in page cache
		%% should generally be a good thing
                _ = file:advise(FstFd, 0, 0, random),
                {ok, <<FstO:64/unsigned,
                       _FstTimestamp:64/signed,
                       FstE:64/unsigned,
                       _FstChunkPos:32/unsigned,
                       _FstChType:8/unsigned>>} = first_idx_record(FstFd),
                ok = file:close(FstFd),
                NonEmptyIdxFiles = non_empty_index_files(IdxFiles),
                {LastE, LastO, Res} =
                    lists:foldl(
                      fun(IdxFile, {E, _, EOs} = Acc) ->
                              Fd = open_index_read(IdxFile),
                              {ok, <<Offset:64/unsigned,
                                     _Timestamp:64/signed,
                                     Epoch:64/unsigned,
                                     _LastChunkPos:32/unsigned,
                                     _ChType:8/unsigned>>} =
                                  last_valid_idx_record(IdxFile),
                              case Epoch > E of
                                  true ->
                                      %% we need to scan as the last index record
                                      %% has a greater epoch
                                      _ = file:advise(Fd, 0, 0, sequential),
                                      {ok, ?IDX_HEADER_SIZE} = file:position(Fd, ?IDX_HEADER_SIZE),
                                      last_epoch_offset(
                                        file:read(Fd, ?INDEX_RECORD_SIZE_B), Fd,
                                        Acc);
                                  false ->
                                      ok = file:close(Fd),
                                      {Epoch, Offset, EOs}
                              end
                      end, {FstE, FstO, []}, NonEmptyIdxFiles),
                lists:reverse([{LastE, LastO} | Res])
        end,
    {Time, Result} = timer:tc(F),
    ?DEBUG("~s:~s/~b completed in ~bms",
           [?MODULE, ?FUNCTION_NAME, ?FUNCTION_ARITY, Time div 1000]),
    Result.

%% aggregates the chunk offsets for each epoch
last_epoch_offset(eof, Fd, Acc) ->
    ok = file:close(Fd),
    Acc;
last_epoch_offset({ok,
                   <<Offset:64/unsigned,
                     _T:64/signed,
                     Epoch:64/unsigned,
                     _:32/unsigned,
                     _ChType:8/unsigned>>},
                  Fd, undefined) ->
    last_epoch_offset(file:read(Fd, ?INDEX_RECORD_SIZE_B), Fd,
                      {Epoch, Offset, []});
last_epoch_offset({ok,
                   <<O:64/unsigned,
                     _T:64/signed,
                     CurEpoch:64/unsigned,
                     _:32/unsigned,
                     _ChType:8/unsigned>>},
                  Fd, {CurEpoch, _LastOffs, Acc}) ->
    %% epoch is unchanged
    last_epoch_offset(file:read(Fd, ?INDEX_RECORD_SIZE_B), Fd,
                      {CurEpoch, O, Acc});
last_epoch_offset({ok,
                   <<O:64/unsigned,
                     _T:64/signed,
                     Epoch:64/unsigned,
                     _:32/unsigned,
                     _ChType:8/unsigned>>},
                  Fd, {CurEpoch, LastOffs, Acc})
  when Epoch > CurEpoch ->
    last_epoch_offset(file:read(Fd, ?INDEX_RECORD_SIZE_B), Fd,
                      {Epoch, O, [{CurEpoch, LastOffs} | Acc]});
last_epoch_offset({ok, _}, Fd, Acc) ->
    %% trailing data in the index file - ignore
    ok = file:close(Fd),
    Acc.


segment_from_index_file(IdxFile) when is_list(IdxFile) ->
    unicode:characters_to_list(string:replace(IdxFile, ".index", ".segment", trailing));
segment_from_index_file(IdxFile) when is_binary(IdxFile) ->
    unicode:characters_to_binary(string:replace(IdxFile, ".index", ".segment", trailing)).

make_chunk(Blobs, TData, ChType, Timestamp, Epoch, Next) ->
    {NumEntries, NumRecords, EData} =
        lists:foldl(fun ({batch, NumRecords, CompType, UncompLen, B},
                         {Entries, Count, Acc}) ->
                            Data =
                                [<<1:1, %% batch record type
                                   CompType:3/unsigned,
                                   0:4/unsigned,
                                   NumRecords:16/unsigned,
                                   UncompLen:32/unsigned,
                                   (iolist_size(B)):32/unsigned>>,
                                 B],
                            {Entries + 1, Count + NumRecords, [Data | Acc]};
                        (B, {Entries, Count, Acc}) ->
                            %% simple record type
                            Data = [<<0:1, (iolist_size(B)):31/unsigned>>, B],
                            {Entries + 1, Count + 1, [Data | Acc]}
                    end,
                    {0, 0, []}, Blobs),

    Size = iolist_size(EData),
    TSize = iolist_size(TData),
    %% checksum is over entry data only
    Crc = erlang:crc32(EData),
    {[<<?MAGIC:4/unsigned,
        ?VERSION:4/unsigned,
        ChType:8/unsigned,
        NumEntries:16/unsigned,
        NumRecords:32/unsigned,
        Timestamp:64/signed,
        Epoch:64/unsigned,
        Next:64/unsigned,
        Crc:32/integer,
        Size:32/unsigned,
        TSize:32/unsigned,
        0:32/unsigned>>,
      EData, TData],
     NumRecords}.

write_chunk(Chunk,
            ChType,
            Timestamp,
            Epoch,
            NumRecords,
            #?MODULE{cfg = #cfg{counter = CntRef,
                                shared = Shared} = Cfg,
                     fd = Fd,
                     index_fd = IdxFd,
                     mode =
                         #write{segment_size = {SegSizeBytes, SegSizeChunks},
                                tail_info = {Next, _}} =
                             Write} =
                State) ->
    case max_segment_size_reached(State) of
        true ->
            trigger_retention_eval(
              write_chunk(Chunk,
                          ChType,
                          Timestamp,
                          Epoch,
                          NumRecords,
                          open_new_segment(State)));
        false ->
            NextOffset = Next + NumRecords,
            Size = iolist_size(Chunk),
            {ok, Cur} = file:position(Fd, cur),
            ok = file:write(Fd, Chunk),

            ok = file:write(IdxFd,
                            <<Next:64/unsigned,
                              Timestamp:64/signed,
                              Epoch:64/unsigned,
                              Cur:32/unsigned,
                              ChType:8/unsigned>>),
            osiris_log_shared:set_last_chunk_id(Shared, Next),
            %% update counters
            counters:put(CntRef, ?C_OFFSET, NextOffset - 1),
            counters:add(CntRef, ?C_CHUNKS, 1),
            maybe_set_first_offset(Next, Cfg),
            State#?MODULE{mode =
                          Write#write{tail_info =
                                      {NextOffset,
                                       {Epoch, Next, Timestamp}},
                                      segment_size = {SegSizeBytes + Size,
                                                      SegSizeChunks + 1}}}
    end.


maybe_set_first_offset(0, #cfg{shared = Ref}) ->
    osiris_log_shared:set_first_chunk_id(Ref, 0);
maybe_set_first_offset(_, _Cfg) ->
    ok.

max_segment_size_reached(
  #?MODULE{mode = #write{segment_size = {CurrentSizeBytes,
                                         CurrentSizeChunks}},
           cfg = #cfg{max_segment_size_bytes = MaxSizeBytes,
                      max_segment_size_chunks = MaxSizeChunks}}) ->
    CurrentSizeBytes >= MaxSizeBytes orelse
    CurrentSizeChunks >= MaxSizeChunks.

setopts(tcp, Sock, Opts) ->
    ok = inet:setopts(Sock, Opts);
setopts(ssl, Sock, Opts) ->
    ok = ssl:setopts(Sock, Opts).

sendfile(_Transport, _Fd, _Sock, _Pos, 0) ->
    ok;
sendfile(tcp = Transport, Fd, Sock, Pos, ToSend) ->
    case file:sendfile(Fd, Sock, Pos, ToSend, []) of
        {ok, 0} ->
            %% TODO add counter for this?
            sendfile(Transport, Fd, Sock, Pos, ToSend);
        {ok, BytesSent} ->
            sendfile(Transport, Fd, Sock, Pos + BytesSent, ToSend - BytesSent);
        {error, _} = Err ->
            Err
    end;
sendfile(ssl, Fd, Sock, Pos, ToSend) ->
    case file:pread(Fd, Pos, ToSend) of
        {ok, Data} ->
            ssl:send(Sock, Data);
        {error, _} = Err ->
            Err
    end.

last_timestamp_in_index_file(IdxFile) ->
    case file:open(IdxFile, [raw, binary, read]) of
        {ok, IdxFd} ->
            case last_idx_record(IdxFd) of
                {ok, <<_O:64/unsigned,
                       LastTimestamp:64/signed,
                       _E:64/unsigned,
                       _ChunkPos:32/unsigned,
                       _ChType:8/unsigned>>} ->
                    _ = file:close(IdxFd),
                    {ok, LastTimestamp};
                Err ->
                    _ = file:close(IdxFd),
                    Err
            end;
        Err ->
            Err
    end.

first_timestamp_from_index_files([IdxFile | _]) ->
    case file:open(IdxFile, [raw, binary, read]) of
        {ok, IdxFd} ->
            case first_idx_record(IdxFd) of
                {ok, <<_FstO:64/unsigned,
                       FstTimestamp:64/signed,
                       _FstE:64/unsigned,
                       _FstChunkPos:32/unsigned,
                       _FstChType:8/unsigned>>} ->
                    _ = file:close(IdxFd),
                    FstTimestamp;
                _ ->
                    _ = file:close(IdxFd),
                    0
            end;
        _Err ->
            0
    end;
first_timestamp_from_index_files([]) ->
    0.

offset_range_from_idx_files([]) ->
    empty;
offset_range_from_idx_files([IdxFile]) ->
    %% there is an invariant that if there is a single index file
    %% there should also be a segment file
    {ok, #seg_info{first = First,
                   last = Last}} = build_seg_info(IdxFile),
    offset_range_from_chunk_range({First, Last});
offset_range_from_idx_files(IdxFiles) when is_list(IdxFiles) ->
    NonEmptyIdxFiles = non_empty_index_files(IdxFiles),
    {_, FstSI, LstSI} = first_and_last_seginfos0(NonEmptyIdxFiles),
    ChunkRange = chunk_range_from_segment_infos([FstSI, LstSI]),
    offset_range_from_chunk_range(ChunkRange).

offset_range_from_segment_infos(SegInfos) ->
    ChunkRange = chunk_range_from_segment_infos(SegInfos),
    offset_range_from_chunk_range(ChunkRange).

chunk_range_from_segment_infos([#seg_info{first = undefined,
                                          last = undefined}]) ->
    empty;
chunk_range_from_segment_infos(SegInfos) when is_list(SegInfos) ->
    #seg_info{first = First} = hd(SegInfos),
    #seg_info{last = Last} = lists:last(SegInfos),
    {First, Last}.

offset_range_from_chunk_range(empty) ->
    empty;
offset_range_from_chunk_range({undefined, undefined}) ->
    empty;
offset_range_from_chunk_range({#chunk_info{id = FirstChId},
                               #chunk_info{id = LastChId,
                                           num = LastNumRecs}}) ->
    {FirstChId, LastChId + LastNumRecs - 1}.

find_segment_for_offset(Offset, IdxFiles) ->
    %% we assume index files are in the default low-> high order here
    case lists:search(
           fun(IdxFile) ->
                   Offset >= index_file_first_offset(IdxFile)
           end, lists:reverse(IdxFiles)) of
        {value, File} ->
            case build_seg_info(File) of
                {ok, #seg_info{first = undefined,
                               last = undefined} = Info} ->
                    {end_of_log, Info};
                {ok, #seg_info{last =
                               #chunk_info{id = LastChId,
                                           num = LastNumRecs}} = Info}
                  when Offset == LastChId + LastNumRecs ->
                    %% the last segment and offset is the next offset
                    {end_of_log, Info};
                {ok, #seg_info{first = #chunk_info{id = FirstChId},
                               last = #chunk_info{id = LastChId,
                                                  num = LastNumRecs}} = Info} ->
                    NextChId = LastChId + LastNumRecs,
                    case Offset >= FirstChId andalso Offset < NextChId of
                        true ->
                            %% we found it
                            {found, Info};
                        false ->
                            not_found
                    end;
                {error, _} = Err ->
                    Err
            end;
        false ->
            not_found
    end.

can_read_next_chunk_id(#?MODULE{mode = #read{type = offset,
                                             next_offset = NextOffset},
                              cfg = #cfg{shared = Ref}}) ->
    osiris_log_shared:committed_chunk_id(Ref) >= NextOffset;
can_read_next_chunk_id(#?MODULE{mode = #read{type = data,
                                             next_offset = NextOffset},
                              cfg = #cfg{shared = Ref}}) ->
    osiris_log_shared:last_chunk_id(Ref) >= NextOffset.

incr_next_offset(Num, #read{next_offset = NextOffset} = Read) ->
    Read#read{next_offset = NextOffset + Num}.

make_file_name(N, Suff) ->
    lists:flatten(
        io_lib:format("~20..0B.~s", [N, Suff])).

open_new_segment(#?MODULE{cfg = #cfg{name = Name,
                                     directory = Dir,
                                     counter = Cnt},
                          fd = OldFd,
                          index_fd = OldIdxFd,
                          mode = #write{type = _WriterType,
                                        tail_info = {NextOffset, _}} = Write} =
                 State0) ->
    _ = close_fd(OldFd),
    _ = close_fd(OldIdxFd),
    Filename = make_file_name(NextOffset, "segment"),
    IdxFilename = make_file_name(NextOffset, "index"),
    ?DEBUG("~s: ~s ~s: ~s", [?MODULE, ?FUNCTION_NAME, Name, Filename]),
    {ok, IdxFd} =
        file:open(
            filename:join(Dir, IdxFilename), ?FILE_OPTS_WRITE),
    ok = file:write(IdxFd, ?IDX_HEADER),
    {ok, Fd} =
        file:open(
            filename:join(Dir, Filename), ?FILE_OPTS_WRITE),
    ok = file:write(Fd, ?LOG_HEADER),
    %% we always move to the end of the file
    {ok, _} = file:position(Fd, eof),
    {ok, _} = file:position(IdxFd, eof),
    counters:add(Cnt, ?C_SEGMENTS, 1),

    State0#?MODULE{current_file = Filename,
                   fd = Fd,
                   %% reset segment_size counter
                   index_fd = IdxFd,
                   mode = Write#write{segment_size = {?LOG_HEADER_SIZE, 0}}}.

open_index_read(File) ->
    {ok, Fd} = open(File, [read, raw, binary, read_ahead]),
    %% We can't use the assertion that index header is correct because of a
    %% race condition between opening the file and writing the header
    %% It seems to happen when retention policies are applied
    {ok, ?IDX_HEADER_SIZE} = file:position(Fd, ?IDX_HEADER_SIZE),
    Fd.

offset_idx_scan(Offset, #seg_info{index = IndexFile} = SegmentInfo) ->
    {Time, Result} =
        timer:tc(
          fun() ->
                  case offset_range_from_segment_infos([SegmentInfo]) of
                      empty ->
                          eof;
                      {SegmentStartOffs, SegmentEndOffs} ->
                          case Offset < SegmentStartOffs orelse
                               Offset > SegmentEndOffs of
                              true ->
                                  offset_out_of_range;
                              false ->
                                  IndexFd = open_index_read(IndexFile),
								  _ = file:advise(IndexFd, 0, 0, sequential),
                                  offset_idx_scan0(IndexFd, Offset, not_found)
                          end
                  end
          end),
    ?DEBUG("~s:~s/~b completed in ~fs",
           [?MODULE, ?FUNCTION_NAME, ?FUNCTION_ARITY, Time/1000000]),
    Result.

offset_idx_scan0(Fd, Offset, PreviousChunk) ->
    case file:read(Fd, ?INDEX_RECORD_SIZE_B) of
        {ok, <<ChunkId:64/unsigned,
               _Timestamp:64/signed,
               Epoch:64/unsigned,
               FilePos:32/unsigned,
               _ChType:8/unsigned>>} ->
            case Offset < ChunkId of
                true ->
                    %% offset we are looking for is higher or equal
                    %% to the start of the previous chunk
                    %% but lower than the start of the current chunk ->
                    %% return the previous chunk
                    _ = file:close(Fd),
                    PreviousChunk;
                false ->
                    offset_idx_scan0(Fd, Offset, {ChunkId, Epoch, FilePos})
            end;
        eof ->
            _ = file:close(Fd),
            %% Offset must be in the last chunk as there is no more data
            PreviousChunk;
        {error, Posix} ->
            _ = file:close(Fd),
            Posix
    end.

throw_missing({error, enoent}) ->
    throw(missing_file);
throw_missing(Any) ->
    Any.

open(File, Options) ->
    throw_missing(file:open(File, Options)).

chunk_location_for_timestamp(Idx, Ts) ->
    Fd = open_index_read(Idx),
    %% scan index file for nearest timestamp
    {ChunkId, _Timestamp, _Epoch, FilePos} = timestamp_idx_scan(Fd, Ts),
    {ChunkId, FilePos}.

timestamp_idx_scan(Fd, Ts) ->
    case file:read(Fd, ?INDEX_RECORD_SIZE_B) of
        {ok,
         <<ChunkId:64/unsigned,
           Timestamp:64/signed,
           Epoch:64/unsigned,
           FilePos:32/unsigned,
           _ChType:8/unsigned>>} ->
            case Ts =< Timestamp of
                true ->
                    ok = file:close(Fd),
                    {ChunkId, Timestamp, Epoch, FilePos};
                false ->
                    timestamp_idx_scan(Fd, Ts)
            end;
        eof ->
            ok = file:close(Fd),
            eof
    end.

validate_crc(ChunkId, Crc, IOData) ->
    case erlang:crc32(IOData) of
        Crc ->
            ok;
        _ ->
            ?ERROR("crc validation failure at chunk id ~bdata size "
                   "~b:",
                   [ChunkId, iolist_size(IOData)]),
            exit({crc_validation_failure, {chunk_id, ChunkId}})
    end.

make_counter(#{counter_spec := {Name, Fields}}) ->
    %% create a registered counter
    osiris_counters:new(Name, ?COUNTER_FIELDS ++ Fields);
make_counter(_) ->
    %% if no spec is provided we create a local counter only
    counters:new(?C_NUM_LOG_FIELDS, []).

counter_id(#{counter_spec := {Name, _}}) ->
    Name;
counter_id(_) ->
    undefined.

part(0, _) ->
    [];
part(Len, [B | L]) when Len > 0 ->
    S = byte_size(B),
    case Len > S of
        true ->
            [B | part(Len - byte_size(B), L)];
        false ->
            [binary:part(B, {0, Len})]
    end.

-spec recover_tracking(state()) ->
    osiris_tracking:state().
recover_tracking(#?MODULE{cfg = #cfg{tracking_config = TrkConfig},
                          fd = Fd}) ->
    %% TODO: if the first chunk in the segment isn't a tracking snapshot and
    %% there are prior segments we could scan at least two segments increasing
    %% the chance of encountering a snapshot and thus ensure we don't miss any
    %% tracking entries
    {ok, 0} = file:position(Fd, 0),
    {ok, ?LOG_HEADER_SIZE} = file:position(Fd, ?LOG_HEADER_SIZE),
    Trk = osiris_tracking:init(undefined, TrkConfig),
    recover_tracking(Fd, Trk).

recover_tracking(Fd, Trk0) ->
    case file:read(Fd, ?HEADER_SIZE_B) of
        {ok,
         <<?MAGIC:4/unsigned,
           ?VERSION:4/unsigned,
           ChType:8/unsigned,
           _:16/unsigned,
           _NumRecords:32/unsigned,
           _Timestamp:64/signed,
           _Epoch:64/unsigned,
           ChunkId:64/unsigned,
           _Crc:32/integer,
           Size:32/unsigned,
           TSize:32/unsigned,
           _Reserved:32>>} ->
            case ChType of
                ?CHNK_TRK_DELTA ->
                    %% tracking is written a single record so we don't
                    %% have to parse
                    {ok, <<0:1, S:31, Data:S/binary>>} = file:read(Fd, Size),
                    Trk = osiris_tracking:append_trailer(ChunkId, Data, Trk0),
                    {ok, _} = file:position(Fd, {cur, TSize}),
                    %% A tracking delta chunk will not have any writer data
                    %% so no need to parse writers here
                    recover_tracking(Fd, Trk);
                ?CHNK_TRK_SNAPSHOT ->
                    {ok, <<0:1, S:31, Data:S/binary>>} = file:read(Fd, Size),
                    {ok, _} = file:read(Fd, TSize),
                    Trk = osiris_tracking:init(Data, Trk0),
                    recover_tracking(Fd, Trk);
                ?CHNK_USER ->
                    {ok, _} = file:position(Fd, {cur, Size}),
                    {ok, TData} = file:read(Fd, TSize),

                    Trk = osiris_tracking:append_trailer(ChunkId, TData, Trk0),
                    recover_tracking(Fd, Trk)
            end;
        eof ->
            Trk0
    end.

read_header0(#?MODULE{cfg = #cfg{directory = Dir,
                                 shared = Shared,
                                 counter = CntRef},
                      mode = #read{next_offset = NextChId0} = Read0,
                      current_file = CurFile,
                      fd = Fd} =
                 State) ->
    %% reads the next header if permitted
    case can_read_next_chunk_id(State) of
        true ->
            {ok, Pos} = file:position(Fd, cur),
            case file:read(Fd, ?HEADER_SIZE_B) of
                {ok,
                 <<?MAGIC:4/unsigned,
                   ?VERSION:4/unsigned,
                   ChType:8/unsigned,
                   NumEntries:16/unsigned,
                   NumRecords:32/unsigned,
                   Timestamp:64/signed,
                   Epoch:64/unsigned,
                   NextChId0:64/unsigned,
                   Crc:32/integer,
                   DataSize:32/unsigned,
                   TrailerSize:32/unsigned,
                   _Reserved:32>> =
                     HeaderData} ->
                    counters:put(CntRef, ?C_OFFSET, NextChId0 + NumRecords),
                    counters:add(CntRef, ?C_CHUNKS, 1),
                    {ok,
                     #{chunk_id => NextChId0,
                       epoch => Epoch,
                       type => ChType,
                       crc => Crc,
                       num_records => NumRecords,
                       num_entries => NumEntries,
                       timestamp => Timestamp,
                       data_size => DataSize,
                       trailer_size => TrailerSize,
                       header_data => HeaderData,
                       position => Pos},
                     State};
                {ok, Bin} when byte_size(Bin) < ?HEADER_SIZE_B ->
                    %% partial header read
                    %% this can happen when a replica reader reads ahead
                    %% optimistically
                    %% set the position back and and return end of stream
                    {ok, Pos} = file:position(Fd, Pos),
                    {end_of_stream, State};
                eof ->
                    FirstOffset = osiris_log_shared:first_chunk_id(Shared),
                    %% open next segment file and start there if it exists
                    NextChId = max(FirstOffset, NextChId0),
                    %% TODO: replace this check with a last chunk id counter
                    %% updated by the writer and replicas
                    SegFile = make_file_name(NextChId, "segment"),
                    case SegFile == CurFile of
                        true ->
                            %% the new filename is the same as the old one
                            %% this should only really happen for an empty
                            %% log but would cause an infinite loop if it does
                            {end_of_stream, State};
                        false ->
                            case file:open(
                                     filename:join(Dir, SegFile),
                                     [raw, binary, read])
                            of
                                {ok, Fd2} ->
                                    ok = file:close(Fd),
                                    {ok, _} =
                                        file:position(Fd2, ?LOG_HEADER_SIZE),
                                    Read = Read0#read{next_offset = NextChId},
                                    read_header0(State#?MODULE{current_file =
                                                                   SegFile,
                                                               fd = Fd2,
                                                               mode = Read});
                                {error, enoent} ->
                                    {end_of_stream, State}
                            end
                    end;
                {ok,
                 <<?MAGIC:4/unsigned,
                   ?VERSION:4/unsigned,
                   _ChType:8/unsigned,
                   _NumEntries:16/unsigned,
                   _NumRecords:32/unsigned,
                   _Timestamp:64/signed,
                   _Epoch:64/unsigned,
                   UnexpectedChId:64/unsigned,
                   _Crc:32/integer,
                   _DataSize:32/unsigned,
                   _TrailerSize:32/unsigned,
                   _Reserved:32>>} ->
                    %% TODO: we may need to return the new state here if
                    %% we've crossed segments
                    {ok, Pos} = file:position(Fd, Pos),
                    {error, {unexpected_chunk_id, UnexpectedChId, NextChId0}};
                Invalid ->
                    _ = file:position(Fd, Pos),
                    {error, {invalid_chunk_header, Invalid}}
            end;
        false ->
            {end_of_stream, State}
    end.

trigger_retention_eval(#?MODULE{cfg =
                                    #cfg{name = Name,
                                         directory = Dir,
                                         retention = RetentionSpec,
                                         counter = Cnt,
                                         shared = Shared}} = State) ->

    %% updates first offset and first timestamp
    %% after retention has been evaluated
    EvalFun = fun ({{FstOff, _}, FstTs, NumSegLeft})
                    when is_integer(FstOff),
                         is_integer(FstTs) ->
                      osiris_log_shared:set_first_chunk_id(Shared, FstOff),
                      counters:put(Cnt, ?C_FIRST_OFFSET, FstOff),
                      counters:put(Cnt, ?C_FIRST_TIMESTAMP, FstTs),
                      counters:put(Cnt, ?C_SEGMENTS, NumSegLeft);
                  (_) ->
                      ok
              end,
    ok = osiris_retention:eval(Name, Dir, RetentionSpec, EvalFun),
    State.

next_location(undefined) ->
    {0, ?LOG_HEADER_SIZE};
next_location(#chunk_info{id = Id,
                          num = Num,
                          pos = Pos,
                          size = Size}) ->
    {Id + Num, Pos + Size + ?HEADER_SIZE_B}.

index_file_first_offset(IdxFile) when is_list(IdxFile) ->
    list_to_integer(filename:basename(IdxFile, ".index"));
index_file_first_offset(IdxFile) when is_binary(IdxFile) ->
    binary_to_integer(filename:basename(IdxFile, <<".index">>)).

first_last_timestamps(IdxFile) ->
    case file:open(IdxFile, [raw, read, binary]) of
        {ok, Fd} ->
	    _ = file:advise(Fd, 0, 0, random),
            case first_idx_record(Fd) of
                {ok, <<_:64/unsigned,
                       FirstTs:64/signed,
                       _:64/unsigned,
                       _:32/unsigned,
                       _:8/unsigned>>} ->
                    %% if we can get the first we can get the last
                    {ok, <<_:64/unsigned,
                           LastTs:64/signed,
                           _:64/unsigned,
                           _:32/unsigned,
                           _:8/unsigned>>} = last_idx_record(Fd),
                    ok = file:close(Fd),
                    {FirstTs, LastTs};
                {error, einval} ->
                    %% empty index
                    undefined;
                eof ->
                    eof
            end;
        _Err ->
            file_not_found
    end.



%% accepts a list of index files in reverse order
%% [{21, 30}, {12, 20}, {5, 10}]
%% 11 = {12, 20}
timestamp_idx_file_search(Ts, [FstIdxFile | Older]) ->
    case first_last_timestamps(FstIdxFile) of
        {_FstTs, EndTs}
          when Ts > EndTs ->
            %% timestamp greater than the newest timestamp in the stream
            %% attach at 'next'
            next;
        {FstTs, _EndTs}
          when Ts < FstTs ->
            %% the requested timestamp is older than the first timestamp in
            %% this segment, keep scanning
            timestamp_idx_file_search0(Ts, Older, FstIdxFile);
        {_, _} ->
            %% else we must have found it!
            {scan, FstIdxFile};
        file_not_found ->
            %% the requested timestamp is older than the first timestamp in
            %% this segment, keep scanning
            timestamp_idx_file_search0(Ts, Older, FstIdxFile);
        eof ->
            %% empty log
            next
    end.

timestamp_idx_file_search0(Ts, [], IdxFile) ->
    case first_last_timestamps(IdxFile) of
        {FstTs, _LastTs}
          when Ts < FstTs ->
            {first_in, IdxFile};
        _ ->
            {found, IdxFile}
    end;
timestamp_idx_file_search0(Ts, [IdxFile | Older], Prev) ->
    case first_last_timestamps(IdxFile) of
        {_FstTs, EndTs}
          when Ts > EndTs ->
            %% we should attach the the first chunk in the previous segment
            %% as the requested timestamp must fall in between the
            %% current and previous segments
            {first_in, Prev};
        {FstTs, _EndTs}
          when Ts < FstTs ->
            %% the requested timestamp is older than the first timestamp in
            %% this segment, keep scanning
            timestamp_idx_file_search0(Ts, Older, IdxFile);
        _ ->
            %% else we must have found it!
            {scan, IdxFile}
    end.

close_fd(undefined) ->
    ok;
close_fd(Fd) ->
    _ = file:close(Fd),
    ok.

-ifdef(TEST).

% -include_lib("eunit/include/eunit.hrl").

part_test() ->
    [<<"ABCD">>] = part(4, [<<"ABCDEF">>]),
    [<<"AB">>, <<"CD">>] = part(4, [<<"AB">>, <<"CDEF">>]),
    [<<"AB">>, <<"CDEF">>] = part(6, [<<"AB">>, <<"CDEF">>]),
    ok.

-endif.
