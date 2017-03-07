%%%---------------------------------------------------------------------------
%% @doc erllambda_v1_http - Erllambda Application HTTP endpoint
%%
%% This module implements the Cowboy request handler, used by the javascript
%% driver to interface with the Erlang node.
%%
%%
%% @copyright 2016 Alert Logic, Inc
%% @author Paul Fisher <pfisher@alertlogic.com>
%%%---------------------------------------------------------------------------
-module(erllambda_v1_http).
-author('Paul Fisher <pfisher@alertlogic.com>').

-export([init/2, terminate/3]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.


%%====================================================================
%% Cowboy handler functions
%%====================================================================
%%%--------------------------------------------------------------------
-spec init( Request :: cowboy_req:req(), [] ) ->
          {ok, Req :: cowboy_req:req(), State :: undefined}.
%%%--------------------------------------------------------------------
%% @private
%%
%% @doc Callback to process the cowboy http request
%%
%% This function is called for each request, and blocks until complete.
%%
init( Request, [] ) ->
    Method = method( cowboy_req:method( Request ) ),
    <<"/eee/v1/", Module/binary>> = cowboy_req:path( Request ),
    NewRequest =
        try request( Method, Module, Request ) of
            {ok, Status, MethodRequest} ->
                cowboy_req:reply( Status, MethodRequest );
            {ok, Status, Headers, Body, MethodRequest} ->
                cowboy_req:reply( Status, Headers, Body, MethodRequest )
        catch
            Type:Reason ->
                Trace = erlang:get_stacktrace(),
                error_logger:error_report(
                  {request_failed, {Type, Reason}, Trace} ),
                Body = jiffy:encode( #{error => #{type => Type,
                                                  reason => Reason}} ),
                cowboy_req:reply( 200, json_headers(), Body, Request )  
        end,
    {ok, NewRequest, undefined}.


%%%--------------------------------------------------------------------
-spec terminate( Reason :: any(), Request :: cowboy_req:req(),
                 State :: undefined ) -> ok.
%%%--------------------------------------------------------------------
%% @private
%%
%% @doc Callback to process the termination of a cowboy http request
%%
%% This function should cleanup any resources allocated to this process
%% during other callback processing (which should be accounted for in the
%% state), in order to allow the process to be reused to for the next
%% pipelined request.  If this cleanup cannot be accomplished with
%% certainty, then this callback should crash, which will terminate the
%% process.
%%
terminate( _Reason, _Request, [] ) -> ok.



%%===========================================================================
%% Internal functions
%%===========================================================================
method( <<"GET">> ) -> get;
method( <<"POST">> ) -> post.

    
request( get, BinModule, Request ) ->
    try binary_to_existing_atom( BinModule, latin1 ) of
        Module ->
            case code:is_loaded( Module ) of
                {file, _Filename} ->
                    {ok, 200, Request};
                false ->
                    {ok, 200, json_headers(),
                     <<"{\"error\": \"module is unknown\"}">>, Request}
            end
    catch
        error:badarg ->
            {ok, 200, json_headers(),
             <<"{\"error\": \"module is unknown\"}">>, Request}
    end;
request( post, BinModule, Request ) ->
    try binary_to_existing_atom( BinModule, latin1 ) of
        Module ->
            case cowboy_req:has_body( Request ) of
                true ->
                    post_body( Module, Request );
                false ->
                    {ok, 200, json_headers(),
                     <<"{\"error\": \"body missing from post\"}">>, Request}
            end
    catch
        error:badarg ->
            {ok, 200, json_headers(),
             <<"{\"error\": \"module is unknown\"}">>, Request}
    end.

post_body( Module, Request ) ->
    case post_body_read( Request, <<>> ) of
        {ok, Body, NewRequest} ->
            post_process( Module, Body, NewRequest );
        Otherwise -> Otherwise
    end.

post_body_read( Request, Body ) ->
    case cowboy_req:read_body( Request ) of
        {ok, Data, NewRequest} ->
            NewBody = <<Body/binary, Data/binary>>,
            {ok, NewBody, NewRequest};
        {more, Data, NewRequest} ->
            NewBody = <<Body/binary, Data/binary>>,
            post_body_read( NewRequest, NewBody );
        Otherwise -> Otherwise
    end.

post_process( Module, Body, Request ) ->
    try jiffy:decode( Body, [return_maps] ) of
        #{<<"event">> := Event, <<"context">> := Context} ->
            Response = erllambda:invoke( Module, Event, Context ),
            {ok, 200, json_headers(), Response, Request};
        #{<<"context">> := _} ->
            {ok, 200, json_headers(),
             <<"{\"error\": \"'event' missing from post json\"}">>, Request};
        _Invalid ->
            {ok, 200, json_headers(),
             <<"{\"error\": \"'context' missing from post json\"}">>, Request}
    catch
        error:badarg ->
            {ok, 200, json_headers(),
             <<"{\"error\": \"post json failed to parse\"}">>, Request}
    end.            


json_headers() ->
    #{<<"content-type">> => <<"application/json">>}.
