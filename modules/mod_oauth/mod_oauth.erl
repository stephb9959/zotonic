%% @author Arjan Scherpenisse <arjan@scherpenisse.net>
%% @copyright 2009 Arjan Scherpenisse
%% Date: 2009-10-02
%% @doc OAuth.

%% Copyright 2009 Arjan Scherpenisse
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

-module(mod_oauth).
-author("Arjan Scherpenisse <arjan@scherpenisse.net>").
-behaviour(gen_server).

-mod_title("OAuth").
-mod_description("Provides authentication over OAuth.").
-mod_prio(900).


%% gen_server exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([start_link/1]).

%% interface functions
-export([
         serve_oauth/2,
         request_is_signed/1,
         oauth_param/2,
         to_oauth_consumer/2,
         str_value/2,
         test/0,
         authenticate/2,
         observe_service_authorize/2,
         observe_admin_menu/3
]).

-include_lib("zotonic.hrl").
-include_lib("modules/mod_admin/include/admin_menu.hrl").


%%====================================================================
%% API
%%====================================================================
%% @spec start_link(Args) -> {ok,Pid} | ignore | {error,Error}
%% @doc Starts the server
start_link(Args) when is_list(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore               |
%%                     {stop, Reason}
%% @doc Initiates the server.
init(Args) ->
    process_flag(trap_exit, true),
    {context, Context} = proplists:lookup(context, Args),
    install_check(Context),
    {ok, []}.

%% @spec handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% @doc Trap unknown calls
handle_call(Message, _From, State) ->
    {stop, {unknown_call, Message}, State}.


%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @doc Trap unknown casts
handle_cast(Message, State) ->
    {stop, {unknown_cast, Message}, State}.



%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% @doc Handling all non call/cast messages
handle_info(_Info, State) ->
    {noreply, State}.

%% @spec terminate(Reason, State) -> void()
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
terminate(_Reason, _State) ->
    ok.

%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @doc Convert process state when code is changed

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%====================================================================
%% support functions
%%====================================================================

%%
%% Put this in a request to have it optionally served over OAuth.
%% Returns {true, NewContext} when succeeded, or {false, WebmachineResponse} when not.
%% Note that when the request is not signed, it will succeed as well, indicated with a 'none' atom.
%%
check_request_logon(Context) ->
    % request is signed; verify it.
    case request_is_signed(Context) of
        false ->
            % Request was not signed.
            {none, Context};
        true ->
            case serve_oauth(Context,
                fun(URL, Params, Consumer, Signature) ->
                        case oauth_param(<<"oauth_token">>, Context) of
                            undefined ->
                                {false, authenticate(<<"Missing OAuth token.">>, Context)};
                            ParamToken ->
                                case m_oauth_app:secrets_for_verify(access, Consumer, ParamToken, Context) of
                                    undefined ->
                                        {false, authenticate(<<"Access token not found.">>, Context)};
                                    Token ->
                                        case m_oauth_app:check_nonce(
                                                Consumer,
                                                Token,
                                                oauth_param(<<"oauth_timestamp">>, Context),
                                                oauth_param(<<"oauth_nonce">>, Context),
                                                Context)
                                        of
                                            {false, Reason} ->
                                                {false, authenticate(Reason, Context)};
                                            true ->
                                                SigMethod = oauth_param(<<"oauth_signature_method">>, Context),
                                                case oauth:verify(z_convert:to_list(Signature),
                                                                  z_convert:to_list(m_req:get(method, Context)),
                                                                  URL,
                                                                  Params,
                                                                  to_oauth_consumer(Consumer, SigMethod),
                                                                  str_value(token_secret, Token))
                                                of
                                                    true ->
                                                        UID = int_value(user_id, Token),
                                                        Context1 = z_acl:logon(UID, Context),
                                                        Context2 = z_context:set(oauth_consumer, Consumer, Context1),
                                                        {true, Context2};
                                                    false ->
                                                        {false, authenticate(<<"Signature verification failed.">>, Context)}
                                                end
                                        end
                                end
                        end
                end)
            of
                {{halt, Code}, Context2} ->
                    {false, {{halt, Code}, Context2}};
                Other ->
                    Other
            end
    end.

%%
%% This triggers OAuth authentication.
%%
request_is_signed(Context) ->
    case z_context:get_q(<<"oauth_signature">>, Context) of
        undefined ->
            case z_context:get_req_header(<<"authorization">>, Context) of
                <<"OAuth", _/binary>> -> true;
                _ -> false
            end;
        _Sig ->
            true
    end.


%% Helper for to_oauth_params; remove unwanted params.
strip_params([]) ->
    [];
strip_params([{"oauth_signature", _} | T]) ->
    strip_params(T);
strip_params([{"realm", _} | T]) ->
    strip_params(T);
strip_params([H|T]) ->
    [H | strip_params(T)].


%%
%% Transform a webmachine reqdata structure into the parameters that
%% are considered for OAuth signature verification.
%%
to_oauth_params(Context) ->
    Req = z_context:get_q_all(Context),
    AuthHeader = z_context:get_req_header(<<"authorization">>, Context),
    Params = case AuthHeader of
        <<"OAuth ", OAuthHeader/binary>> ->
            oauth:header_params_decode(z_convert:to_list(OAuthHeader)) ++ Req;
        _ ->
            Req
    end,
    Params1 = [ {z_convert:to_list(K), z_convert:to_list(V)} || {K,V} <- Params ],
    strip_params(Params1).


%%
%% Get an argument from either the request or the Authorization: header
%%

oauth_param_auth_header(Param, AuthHeader) ->
    case re:run(
            AuthHeader,
            z_convert:to_list(Param) ++ "=\"(.*?)\"",
            [{capture, all_but_first, binary}])
    of
        nomatch -> undefined;
        {match, [Match|_]} -> to_list(z_url:url_decode(Match))
    end.

oauth_param(Param, Context) ->
    % check authorization header
    AuthHeader = z_context:get_req_header(<<"authorization">>, Context),
    case AuthHeader of
        <<"OAuth ", _/binary>> ->
            oauth_param_auth_header(Param, AuthHeader);
        _ ->
            to_list(z_context:get_q(Param, Context))
    end.

serve_oauth(Context, Fun) ->
    Version = oauth_param(<<"oauth_version">>, Context),
    case Version of
        "1.0" ->
            ConsumerKey = oauth_param(<<"oauth_consumer_key">>, Context),
            %SigMethod = oauth_param(<<"oauth_signature_method">>, Context),
            case m_oauth_app:consumer_lookup(ConsumerKey, Context) of
                undefined ->
                    authenticate(<<"Consumer key not found.">>, Context);
                Consumer ->
                    Signature = oauth_param(<<"oauth_signature">>, Context),
                    URL = z_convert:to_list(z_context:abs_url(m_req:get(path, Context), Context)),
                    Fun(URL, to_oauth_params(Context), Consumer, Signature)
            end;
        _ ->
            authenticate("Unsupported OAuth version: " ++ Version ++ "\n", Context)
    end.

%%
%% Helper functions
%%

to_list(undefined) -> undefined;
to_list(B) when is_binary(B) -> z_convert:to_list(B);
to_list(L) when is_list(L) -> L.


str_value(Key, From) ->
    binary_to_list(proplists:get_value(Key, From)).

int_value(Key, From) ->
    z_convert:to_integer(proplists:get_value(Key, From)).


%% Convert a consumer record from the database representation to the presentation that erlang-oauth understands.

to_oauth_consumer(Consumer, "PLAINTEXT") ->
    {str_value(consumer_key, Consumer), str_value(consumer_secret, Consumer), plaintext};
to_oauth_consumer(Consumer, "HMAC-SHA1") ->
    {str_value(consumer_key, Consumer), str_value(consumer_secret, Consumer), hmac_sha1};
to_oauth_consumer(Consumer, "RSA-SHA1") ->
    {str_value(consumer_key, Consumer), str_value(consumer_secret, Consumer), rsa_sha1}.



%%
%% Send a WWW-Authenticate header
%%
authenticate(Reason, Context) ->
    Context1 = cowmachine_req:set_resp_body([Reason,"\n"], Context),
    Context2 = z_context:set_resp_header(
                    <<"www-authenticate">>,
                    <<"OAuth realm=\"\"">>,
                    Context1),
    {{halt, 401}, Context2}.


%% @doc Check is the shop module has been installed.  If not then install all db tables and rscs.
install_check(Context) ->
    case z_db:table_exists(oauth_application_registry, Context) of
        true ->
            ok;
        false ->
            oauth_install_data:install(Context)
    end.

test() ->
    Ctx  = z_context:new(default),
    ?DEBUG(m_oauth_app:consumer_lookup("Foo", Ctx)),
    ok.


%%
%% Whether consumer with this Id is allowed to execute Service.
%%
is_allowed(Id, Service, Context) ->
    not(z_service:needauth(Service)) orelse
        lists:member(Service, [proplists:get_value(service, S)
                               || S <- m_oauth_perms:all_services_for(Id, Context)]).


%% Main authorization hook, called from controller_api
observe_service_authorize(#service_authorize{service_module=Module}, Context) ->
    case check_request_logon(Context) of
        {none, Context} ->
            %% No OAuth; Authentication is required for this module...
            ServiceInfo = z_service:serviceinfo(Module, Context),
            authenticate(
                iolist_to_binary([
                    proplists:get_value(method, ServiceInfo),
                    ": ",
                    z_service:title(Module),
                    "\n\nThis API call requires authentication."
                ]),
                Context);

        {true, AuthorizedContext} ->
            %% OAuth succeeded; check whether we are allowed to exec this module
            ConsumerId = proplists:get_value(id, z_context:get(oauth_consumer, AuthorizedContext)),
            case is_allowed(ConsumerId, Module, AuthorizedContext) of
                true ->
                    {true, AuthorizedContext};
                false ->
                    AuthorizedContext1 = cowmachine_req:set_resp_body(
                                    <<"You are not authorized to execute this API call.\n">>,
                                    AuthorizedContext),
                    {{halt, 403}, AuthorizedContext1}
            end;

        {false, Response} ->
            Response
    end.


observe_admin_menu(#admin_menu{}, Acc, Context) ->
    [
     #menu_item{id=admin_oauth,
                parent=admin_auth,
                label=?__("API access", Context),
                url={admin_oauth},
                visiblecheck={acl, use, ?MODULE}}
     |Acc].
