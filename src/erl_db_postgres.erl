-module(erl_db_postgres).
-behaviour(gen_server).
-behaviour(poolboy_worker).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

%% Only for testing
-export([build_insert_query/1]).

-record(state, {conn}).

start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

init(Args) ->
    Hostname = proplists:get_value(hostname, Args),
    Database = proplists:get_value(database, Args),
    Username = proplists:get_value(username, Args),
    Password = proplists:get_value(password, Args),
    {ok, Conn} = pgsql:connect(Hostname, Username, Password, [
        {database, Database}
    ]),
    {ok, #state{conn=Conn}}.


handle_call({save, Model}, _From, #state{conn=Conn}=State) ->
    Table = erlang:element(1, Model),
    Query = build_insert_query(Model),
    Result = pgsql:equery(Conn, Query, []),
    Reply =
        case Result of
            {ok, _, _, [Id]} ->
                %% Get the primary key
                [PrimKey|_] = get_fields_with_type(primary_key, Model),
                {ok, Model:PrimKey(Id)};
            {error, Reason} ->
                {error, Reason}
        end,

    {reply, Reply, State};
handle_call({squery, Sql}, _From, #state{conn=Conn}=State) ->
    {reply, pgsql:squery(Conn, Sql), State};
handle_call({equery, Stmt, Params}, _From, #state{conn=Conn}=State) ->
    {reply, pgsql:equery(Conn, Stmt, Params), State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{conn=Conn}) ->
    ok = pgsql:close(Conn),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



build_insert_query(Model) ->
    Tablename = atom_to_list(element(1, Model)),
    Fields = Model:fields(),
    {Attributes, Values} =
        lists:foldl(
          fun({Field, primary_key, Args}, {Attrs, Vals}=Acc) ->
                  case proplists:get_value(auto_increment, Args) of
                      true ->
                          Acc;
                      false ->
                          {[atom_to_list(Field)|Attrs], [pack_value(Model:Field())|Vals]}
                  end;
             ({Field, _Type, _Args}, {Attrs, Vals}) ->
                  {[atom_to_list(Field)|Attrs], [pack_value(Model:Field())|Vals]}
          end,
          {[], []}, Fields),
    ["INSERT INTO ", Tablename, " (",
     string:join(Attributes, ", "),
     ") VALUES (",
     string:join(Values, ", "),
     ")",
     " RETURNING id"].

get_fields_with_type(_Type, []) ->
    [];
get_fields_with_type(Type, [{Name, Type, _}|Tl]) ->
    [Name|get_fields_with_type(Type, Tl)];
get_fields_with_type(Type, [_Hd|Tl]) ->
    get_fields_with_type(Type, Tl).

escape_sql(Value) ->
    escape_sql1(Value, []).

escape_sql1([], Acc) ->
    lists:reverse(Acc);
escape_sql1([$'|Rest], Acc) ->
    escape_sql1(Rest, [$', $'|Acc]);
escape_sql1([C|Rest], Acc) ->
    escape_sql1(Rest, [C|Acc]).

pack_datetime({Date, {Y, M, S}}) when is_float(S) ->
    pack_datetime({Date, {Y, M, erlang:round(S)}});
pack_datetime(DateTime) ->
    "TIMESTAMP '" ++ erlydtl_filters:date(DateTime, "c") ++ "'".

pack_now(Now) -> pack_datetime(calendar:now_to_datetime(Now)).

pack_value(undefined) ->
    "null";
pack_value(V) when is_binary(V) ->
    pack_value(binary_to_list(V));
pack_value(V) when is_list(V) ->
    "'" ++ escape_sql(V) ++ "'";
pack_value({MegaSec, Sec, MicroSec}) when is_integer(MegaSec) andalso is_integer(Sec) andalso is_integer(MicroSec) ->
    pack_now({MegaSec, Sec, MicroSec});
pack_value({{_, _, _}, {_, _, _}} = Val) ->
    pack_datetime(Val);
pack_value(Val) when is_integer(Val) ->
    integer_to_list(Val);
pack_value(Val) when is_float(Val) ->
    float_to_list(Val);
pack_value(true) ->
    "TRUE";
pack_value(false) ->
    "FALSE".