-module(octo_http_proxy).
-include("octo.hrl").
-behaviour(gen_server).

-export([start_link/0, stop/0]).
-export([init/1,
         handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-export([request/3, request/4, request/5,
         get_ratelimit/0, get_ratelimit_remaining/0, get_ratelimit_reset/0,
         set_credentials/2]).

-record(ratelimit, {limit, remaining, reset}).
-record(proxy_state, {ratelimit = #ratelimit{},
                      auth_headers = []}).

%% Public functions

request(Method, Url, OctoOpts) ->
  request(Method, Url, OctoOpts, <<>>).
request(Method, Url, OctoOpts, Payload) ->
  request(Method, Url, OctoOpts, Payload, []).
request(Method, Url, OctoOpts, Payload, Options) ->
  gen_server:call(?MODULE, {request, Method, Url, OctoOpts, Payload, Options}).

get_ratelimit() ->
  gen_server:call(?MODULE, {get_ratelimit}).

get_ratelimit_remaining() ->
  gen_server:call(?MODULE, {get_ratelimit_remaining}).

get_ratelimit_reset() ->
  gen_server:call(?MODULE, {get_ratelimit_reset}).

set_credentials(pat, AuthToken) ->
  gen_server:call(?MODULE, {set_credentials, pat, AuthToken}).

%% Callbacks

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
  gen_server:call(?MODULE, stop).

init(_Args) ->
  {ok, #proxy_state{}}.

handle_call(stop, _From, State) ->
  {stop, normal, ok, State};
handle_call({request, Method, Url, OctoOpts, Payload, Opts}, _From, State) ->
  CacheKey = proplists:get_value(octo_cache_key, OctoOpts),

  AuthHeaders = State#proxy_state.auth_headers,
  CachingHeaders = get_caching_headers(CacheKey),
  Headers = AuthHeaders ++ CachingHeaders,

  case hackney:request(Method, Url, Headers, Payload, [with_body | Opts]) of
    {ok, StatusCode, RespHeaders, Body} ->
      NewState = update_ratelimit(RespHeaders, State),

      CacheEntry = extract_headers(RespHeaders),

      case StatusCode of
        304 ->
          {reply, {ok, cached, CacheKey}, NewState};
        _ ->
          Result = {ok, StatusCode, RespHeaders, Body, CacheKey, CacheEntry},

          {reply, Result, NewState}
      end;
    {ok, StatusCode, RespHeaders} ->
      % This branch should only be used if the method is HEAD
      head = Method,

      NewState = update_ratelimit(RespHeaders, State),

      {reply,
       {ok, StatusCode, RespHeaders, <<>>, undefined, #octo_cache_entry{}},
       NewState};
    {error, Error} ->
      {reply, {error, Error}, State}
  end;
handle_call({get_ratelimit}, _From, State) ->
  Ratelimit = State#proxy_state.ratelimit,
  {reply, Ratelimit#ratelimit.limit, State};
handle_call({get_ratelimit_remaining}, _From, State) ->
  Ratelimit = State#proxy_state.ratelimit,
  {reply, Ratelimit#ratelimit.remaining, State};
handle_call({get_ratelimit_reset}, _From, State) ->
  Ratelimit = State#proxy_state.ratelimit,
  {reply, Ratelimit#ratelimit.reset, State};
handle_call({set_credentials, pat, Token}, _From, State) ->
  Headers = [{"Authorization",
              "Basic " ++ base64:encode_to_string(Token ++ ":x-oauth-basic")}],
  NewState = State#proxy_state{auth_headers = Headers},
  {reply, ok, NewState};
handle_call(_Request, _From, State) ->
  {noreply, State}.

handle_cast(_Request, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% Helper functions

update_ratelimit(Headers, State) ->
  Ratelimit = State#proxy_state.ratelimit,

  Update = fun(FieldNo, HeaderName, RatelimitRecord) ->
                Value = case hackney_headers:parse(HeaderName, Headers) of
                          undefined -> undefined;
                          Binary    -> erlang:list_to_integer(
                                         binary:bin_to_list(Binary))
                        end,

                setelement(FieldNo, RatelimitRecord, Value)
            end,

  NewRatelimit = Update(#ratelimit.limit,     <<"X-RateLimit-Limit">>,
                 Update(#ratelimit.remaining, <<"X-RateLimit-Remaining">>,
                 Update(#ratelimit.reset,     <<"X-RateLimit-Reset">>,
                        Ratelimit))),

  State#proxy_state{ratelimit = NewRatelimit}.

get_caching_headers(undefined) -> [];
get_caching_headers(CacheKey) ->
  case octo_cache:retrieve({url, CacheKey}) of
    %% Found some values for the headers; let's use them
    {ok, Value} ->
      Headers  = Value#octo_cache_entry.headers,
      Headers1 = case Headers#octo_cache_headers.etag of
                   undefined -> [];
                   ETag -> [{<<"If-None-Match">>, ETag}]
                 end,
      Headers2 = case Headers#octo_cache_headers.last_modified of
                   undefined -> Headers1;
                   LM -> [{<<"If-Modified-Since">>, LM} | Headers1]
                 end,
      Headers2;
    %% We don't have any headers stored for this request
    _ -> []
  end.

extract_headers(Headers) ->
  ETag          = hackney_headers:parse(<<"ETag">>, Headers),
  Last_Modified = hackney_headers:parse(<<"Last-Modified">>, Headers),

  LinkValue = hackney_headers:parse(<<"Link">>, Headers),
  Link = if LinkValue =/= undefined ->
              %% Turn the value into proplist with keys "next", "prev", "first
              %% and "last"
              lists:map(
                fun(String) ->
                    {match, [URL,Key]} =
                      re:run(
                        String,
                        "^ ?<\([^>]+\)>; rel=\"\([^\"]+\)\"$",
                        [{capture, [1,2], list}]),
                    {list_to_atom(Key), URL}
                end,
                string:tokens(binary:bin_to_list(LinkValue), ","));
            true -> []
         end,

  #octo_cache_entry{
    headers = #octo_cache_headers{
                 etag = ETag,
                 last_modified = Last_Modified,
                 link = Link}}.
