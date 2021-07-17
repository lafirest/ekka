%%--------------------------------------------------------------------
%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

%% Functions related to the management of the RLOG schema
-module(ekka_rlog_schema).

%% API:
-export([mnesia/1, add_table/2, tables_of_shard/1, shards/0]).


-boot_mnesia({mnesia, [boot]}).
-copy_mnesia({mnesia, [copy]}).

-include("ekka_rlog.hrl").
-include_lib("snabbkaffe/include/trace.hrl").

%% WARNING: Treatment of the schema table is different on the core
%% nodes and replicants. Schema transactions on core nodes are
%% replicated via mnesia and therefore this table is consistent, but
%% these updates do not reach the replicants. The replicants use
%% regular mnesia transactions to update the schema, so it might be
%% inconsistent with the core nodes' view.
%%
%% Therefore one should be rather careful with the contents of the
%% rlog_schema table.

%%================================================================================
%% Type declarations
%%================================================================================

%%================================================================================
%% API
%%================================================================================

%% @doc Add a table to the shard
%%
%% Note: currently it's the only schema operation that we support. No
%% removal and no handover of the table between the shards is
%% possible.
%%
%% These operations are too rare and expensive to implement, because
%% they require precise coordination of the shard processes across the
%% entire cluster.
%%
%% Adding an API to remove or modify schema would open possibility to
%% move a table from one shard to another. This requires restarting
%% both shards in a synchronized manner to avoid a race condition when
%% the replicant processes from the old shard import in-flight
%% transactions while the new shard is bootstrapping the table.
%%
%% This is further complicated by the fact that the replicant nodes
%% may consume shard transactions from different core nodes.
%%
%% So the operation of removing a table from the shard would look like
%% this:
%%
%% 1. Do an RPC call to all core nodes to stop the shard
%% 2. Each core node synchronously stops all the attached replicant
%%    processes
%% 3. Only then we are sure that we can avoid data corruption
%%
%% Currently there is no requirement to implement this, so we can get
%% away with managing each shard separately
-spec add_table(ekka_rlog:shard(), ekka_mnesia:table()) -> ok.
add_table(Shard, Table) ->
    case ekka_rlog_config:backend() of
        mnesia ->
            ok;
        rlog ->
            case mnesia:transaction(fun do_add_table/2, [Shard, Table], infinity) of
                {atomic, ok}   -> ok;
                {aborted, Err} -> error({bad_schema, Shard, Table, Err})
            end
    end.

%% @doc Create the internal schema table if needed
mnesia(StartType) ->
    case ekka_rlog_config:backend() of
        rlog -> do_mnesia(StartType);
        _    -> ok
    end.

%% @doc Return the list of tables that belong to the shard.
-spec tables_of_shard(ekka_rlog:shard()) -> [ekka_mnesia:table()].
tables_of_shard(Shard) ->
    %%core = ekka_rlog_config:role(), % assert
    MS = {#?schema{mnesia_table = '$1', shard = Shard}, [], ['$1']},
    {atomic, Tables} = mnesia:transaction(fun mnesia:select/2, [?schema, [MS]], infinity),
    Tables.

%% @doc Return the list of known shards
-spec shards() -> [ekka_rlog:shard()].
shards() ->
    MS = {#?schema{mnesia_table = '_', shard = '$1'}, [], ['$1']},
    {atomic, Shards} = mnesia:transaction(fun mnesia:select/2, [?schema, [MS]], infinity),
    lists:usort(Shards).

%%================================================================================
%% Internal functions
%%================================================================================

-spec load_static_config() -> ok.
load_static_config() ->
    lists:foreach( fun({_App, _Module, Attrs}) ->
                           [add_table(Shard, Table) || {Shard, Table} <- Attrs]
                   end
                 , ekka_boot:all_module_attributes(rlog_shard)
                 ).

do_mnesia(boot) ->
    ok = ekka_mnesia:create_table_internal(?schema, [{type, ordered_set},
                                                     {ram_copies, [node()]},
                                                     {record_name, ?schema},
                                                     {attributes, record_info(fields, ?schema)}
                                                    ]),
    load_static_config();
do_mnesia(copy) ->
    ok = ekka_mnesia:copy_table(?schema, ram_copies).

-spec do_add_table(ekka_rlog:shard(), ekka_mnesia:table()) -> ok.
do_add_table(Shard, Table) ->
    case mnesia:wread({?schema, Table}) of
        [] ->
            ?tp(info, "Adding table to a shard",
                #{ shard => Shard
                 , table => Table
                 , live_change => is_pid(whereis(Shard))
                 }),
            mnesia:write(#?schema{ mnesia_table = Table
                                 , shard = Shard
                                 }),
            ok;
        [#?schema{shard = Shard}] ->
            %% We're just being idempotent here:
            ok;
        _ ->
            error(bad_schema)
    end.
