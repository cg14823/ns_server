%% @author Couchbase <info@couchbase.com>
%% @copyright 2019 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% REST APIs for various features that trigger automatic rebalance.
%%

-module(menelaus_web_auto_rebalance).

-include("ns_common.hrl").
-include("cut.hrl").

%% Retry rebalance attempts
-define(RETRY_ATTEMPTS_MIN, 1).
-define(RETRY_ATTEMPTS_MAX, 3).
%% Retry rebalance after time period in seconds
-define(RETRY_AFTER_MIN, 5).
-define(RETRY_AFTER_MAX, 3600).

-export([handle_get_retry/1,
         handle_post_retry/1,
         handle_get_pending_retry/2,
         handle_cancel_pending_retry/2]).

handle_get_retry(Req) ->
    assert_api_supported(),
    reply_with_retry_settings(Req).

handle_post_retry(Req) ->
    assert_api_supported(),
    validator:handle(
      fun (Values) ->
              New = auto_rebalance_settings:set_retry_rebalance(Values),
              ns_audit:modify_retry_rebalance(Req, New),
              reply_with_retry_settings(Req)
      end, Req, form,
      [validator:required(enabled, _),
       validator:boolean(enabled, _),
       validator:integer(afterTimePeriod,
                         ?RETRY_AFTER_MIN, ?RETRY_AFTER_MAX, _),
       validator:integer(maxAttempts,
                         ?RETRY_ATTEMPTS_MIN, ?RETRY_ATTEMPTS_MAX, _),
       validator:unsupported(_)]).

handle_get_pending_retry(_PoolId, Req) ->
    assert_api_supported(),
    menelaus_util:reply_json(Req, {auto_rebalance:get_pending_retry()}).

handle_cancel_pending_retry(RebID, Req) ->
    assert_api_supported(),
    auto_rebalance:cancel_pending_retry(list_to_binary(RebID), "user"),
    menelaus_util:reply(Req, 200).

reply_with_retry_settings(Req) ->
    Cfg = auto_rebalance_settings:get_retry_rebalance(),
    Settings = [{enabled, proplists:get_value(enabled, Cfg)},
                {afterTimePeriod, proplists:get_value(after_time_period, Cfg)},
                {maxAttempts, proplists:get_value(max_attempts, Cfg)}],
    menelaus_util:reply_json(Req, {Settings}).

assert_api_supported() ->
    menelaus_util:assert_is_enterprise(),
    menelaus_util:assert_is_madhatter().

