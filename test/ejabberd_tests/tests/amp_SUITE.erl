-module(amp_SUITE).
%% @doc Tests for XEP-0079 Advanced Message Processing support
%% @reference <a href="http://xmpp.org/extensions/xep-0079.html">XEP-0079</a>
%% @author <simon.zelazny@erlang-solutions.com>
%% @copyright 2014 Erlang Solutions, Ltd.
%% This work was sponsored by Grindr.com

-compile([export_all]).
-include_lib("common_test/include/ct.hrl").
-include_lib("escalus/include/escalus.hrl").
-include_lib("escalus/include/escalus_xmlns.hrl").
-include_lib("exml/include/exml.hrl").

-define(DOMAIN, <<"localhost">>).

all() -> [{group, Group} || Group <- enabled_group_names()].

enabled_group_names() ->
    [basic, offline, offline_with_multiple_rules] ++
        case is_odbc_enabled() of
            true -> [mam, mam_with_multiple_rules,
                     mam_and_offline, mam_and_offline_with_multiple_rules];
            false -> []
        end.

groups() ->
    [{basic, [parallel, shuffle], basic_test_cases()},
     {offline, [parallel, shuffle], archive_test_cases() ++ offline_test_cases()},
     {offline_with_multiple_rules, [parallel, shuffle], archive_notify_test_cases()},
     {mam, [parallel, shuffle], archive_test_cases()},
     {mam_with_multiple_rules, [parallel, shuffle], archive_notify_test_cases()},
     {mam_and_offline, [parallel, shuffle], archive_test_cases()},
     {mam_and_offline_with_multiple_rules, [parallel, shuffle], archive_notify_test_cases()}].

basic_test_cases() ->
    [initial_service_discovery_test,
     actions_and_conditions_discovery_test,

     unsupported_actions_test,
     unsupported_conditions_test,
     unacceptable_rules_test,

     notify_deliver_direct_test,
     notify_deliver_direct_bare_jid_test,
     notify_deliver_none_test,
     notify_deliver_none_existing_user_test,
     notify_deliver_none_privacy_test,

     notify_match_resource_any_test,
     notify_match_resource_exact_test,
     notify_match_resource_other_test,
     notify_match_resource_other_bare_test,

     error_deliver_direct_test,
     error_deliver_none_test,

     error_deliver_doesnt_apply_test,
     last_rule_applies_test
    ].

archive_test_cases() ->
    archive_drop_and_error_test_cases() ++ archive_notify_test_cases().

archive_drop_and_error_test_cases() ->
    [drop_deliver_stored_test,
     error_deliver_stored_test
    ].

archive_notify_test_cases() ->
    [notify_deliver_direct_test,
     notify_deliver_none_test,
     notify_deliver_stored_test
    ].

offline_test_cases() ->
    [notify_deliver_none_instead_of_stored_filtered_by_privacy_test].

init_per_suite(C) -> escalus:init_per_suite(C).
end_per_suite(C) -> ok = escalus_fresh:clean(), escalus:end_per_suite(C).

init_per_group(GroupName, Config) ->
    ConfigWithModules = dynamic_modules:save_modules(?DOMAIN, Config),
    ConfigWithRules = setup_rules(GroupName, ConfigWithModules),
    dynamic_modules:ensure_modules(?DOMAIN, required_modules(GroupName)),
    ConfigWithRules.

end_per_group(_GroupName, Config) ->
    dynamic_modules:restore_modules(?DOMAIN, Config).

init_per_testcase(Name,C) -> escalus:init_per_testcase(Name,C).
end_per_testcase(Name,C) -> escalus:end_per_testcase(Name,C).

initial_service_discovery_test(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}],
      fun(Alice) ->
              escalus_client:send(Alice, disco_info(Config)),
              Response = escalus_client:wait_for_stanza(Alice),
              escalus:assert(has_feature, [ns_amp()], Response)
      end).

actions_and_conditions_discovery_test(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}],
      fun(Alice) ->
              escalus_client:send(Alice, disco_info_amp_node(Config)),
              Response = escalus_client:wait_for_stanza(Alice),
              assert_has_features(Response,
                                  [ns_amp()
                                  ,<<"http://jabber.org/protocol/amp?action=notify">>
                                  ,<<"http://jabber.org/protocol/amp?action=error">>
                                  ,<<"http://jabber.org/protocol/amp?condition=deliver">>
                                  ,<<"http://jabber.org/protocol/amp?condition=match-resource">>
                                  ])
      end).


unsupported_actions_test(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}, {bob, 1}],
      fun(Alice, Bob) ->
              %% given
              Msg = amp_message_to(Bob, [{deliver, direct, alert}],  % alert is unsupported
                                   <<"A paradoxical payload!">>),
              %% when
              client_sends_message(Alice, Msg),

              % then
              client_receives_amp_error(Alice, {deliver, direct, alert}, <<"unsupported-actions">>)
      end).

unsupported_conditions_test(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}, {bob, 1}],
      fun(Alice, Bob) ->
              %% given
              %% expire-at is unsupported
              Msg = amp_message_to(Bob, [{'expire-at', <<"2020-06-06T12:20:20Z">>, notify}],
                                   <<"Never fade away!">>),
              %% when
              client_sends_message(Alice, Msg),

              % then
              client_receives_amp_error(Alice, {'expire-at', <<"2020-06-06T12:20:20Z">>, notify},
                                   <<"unsupported-conditions">>)
      end).

unacceptable_rules_test(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}, {bob, 1}],
      fun(Alice, Bob) ->
              %% given
              Msg = amp_message_to(Bob, [{broken, rule, spec}
                                        ,{also_broken, rule, spec}
                                        ],
                                   <<"Break all the rules!">>),
              %% when
              client_sends_message(Alice, Msg),

              % then
              client_receives_amp_error(Alice, [{broken, rule, spec}
                                           ,{also_broken, rule, spec}],
                                    <<"not-acceptable">>)
      end).

notify_deliver_direct_test(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}, {bob, 1}],
      fun(Alice,Bob) ->
              %% given
              Msg = amp_message_to(Bob, rules(Config, [{deliver, direct, notify}]),
                                <<"I want to be sure you get this!">>),
              %% when
              client_sends_message(Alice, Msg),

              % then
              client_receives_notification(Alice, Bob, {deliver, direct, notify}),
              client_receives_message(Bob, <<"I want to be sure you get this!">>)
      end).

notify_deliver_direct_bare_jid_test(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}, {bob, 1}],
      fun(Alice,Bob) ->
              %% given
              BobsBareJid = escalus_client:short_jid(Bob),
              Msg = amp_message_to(BobsBareJid, [{deliver, direct, notify}],
                                   <<"One of your resources needs to get this!">>),
              %% when
              client_sends_message(Alice, Msg),

              % then
              client_receives_notification(Alice, BobsBareJid, {deliver, direct, notify}),
              client_receives_message(Bob, <<"One of your resources needs to get this!">>)
      end).

notify_deliver_none_test(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}],
      fun(Alice) ->
              %% given
              StrangerJid = <<"stranger@localhost">>,
              Msg = amp_message_to(StrangerJid, rules(Config, [{deliver, none, notify}]),
                                   <<"A message in a bottle...">>),
              %% when
              client_sends_message(Alice, Msg),

              % then
              client_receives_notification(Alice, StrangerJid, {deliver, none, notify})
      end).

notify_deliver_none_existing_user_test(Config) ->
    FreshConfig = escalus_fresh:create_users(Config, [{alice, 1}, {bob, 1}]),
    escalus:story(
      FreshConfig, [{alice, 1}],
      fun(Alice) ->
              %% given
              BobJid = escalus_users:get_jid(FreshConfig, bob),
              Msg = amp_message_to(BobJid, [{deliver, none, notify}],
                                   <<"A message in a bottle...">>),
              %% when
              client_sends_message(Alice, Msg),

              % then
              client_receives_notification(Alice, BobJid, {deliver, none, notify})
      end).

notify_deliver_none_privacy_test(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}, {bob, 1}],
      fun(Alice, Bob) ->
              %% given
              Msg = amp_message_to(Bob, [{deliver, none, notify}],
                                   <<"Should be filtered by Bob's privacy list">>),
              privacy_helper:set_and_activate(Bob, <<"deny_all_message">>),

              %% when
              client_sends_message(Alice, Msg),

              % then
              % no notification from AMP, just a regular error message
              client_receives_generic_error(Alice, <<"503">>, <<"cancel">>),
              client_receives_nothing(Alice),
              client_receives_nothing(Bob)
      end).

notify_match_resource_any_test(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}, {bob, 4}],
      fun(Alice,Bob,_,_,_) ->
              %% given
              Msg = amp_message_to(Bob, [{'match-resource', any, notify}],
                                   <<"Church-encoded hot-dogs">>),
              %% when
              client_sends_message(Alice, Msg),

              % then
              client_receives_notification(Alice, Bob, {'match-resource', any, notify}),
              client_receives_message(Bob, <<"Church-encoded hot-dogs">>)
      end).

notify_match_resource_exact_test(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}, {bob, 4}],
      fun(Alice,_,_,Bob3,_) ->
              %% given
              Msg = amp_message_to(Bob3, [{'match-resource', exact, notify}],
                                   <<"Resource three, your battery is on fire!">>),
              %% when
              client_sends_message(Alice, Msg),

              % then
              client_receives_notification(Alice, Bob3, {'match-resource', exact, notify}),
              client_receives_message(Bob3, <<"Resource three, your battery is on fire!">>)
      end).

notify_match_resource_other_test(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}, {bob, 1}],
      fun(Alice,Bob) ->
              %% given
              NonmatchingJid = << (escalus_client:short_jid(Bob))/binary,
                                  "/blahblahblah_resource" >>,
              Msg = amp_message_to(NonmatchingJid,
                                   [{'match-resource', other, notify}],
                                    <<"A Bob by any other name!">>),

              %% when
              client_sends_message(Alice, Msg),

              % then
              client_receives_notification(Alice, NonmatchingJid, {'match-resource', other, notify}),
              client_receives_message(Bob, <<"A Bob by any other name!">>)
      end).

notify_match_resource_other_bare_test(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}, {bob, 1}],
      fun(Alice,Bob) ->
              %% given
              BareJid = escalus_client:short_jid(Bob),
              Msg = amp_message_to(BareJid,
                                   [{'match-resource', other, notify}],
                                    <<"A Bob by any other name!">>),

              %% when
              client_sends_message(Alice, Msg),

              % then
              client_receives_notification(Alice, BareJid, {'match-resource', other, notify}),
              client_receives_message(Bob, <<"A Bob by any other name!">>)
      end).

error_deliver_direct_test(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}, {bob, 1}],
      fun(Alice,Bob) ->
              %% given
              Msg = amp_message_to(Bob, [{deliver, direct, error}],
                                   <<"I want to be sure you don't get this!">>),
              %% when
              client_sends_message(Alice, Msg),

              % then
              client_receives_amp_error(Alice, Bob, {deliver, direct, error}, <<"undefined-condition">>),
              client_receives_nothing(Bob)
      end).

error_deliver_none_test(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}],
      fun(Alice) ->
              %% given
              StrangerJid = <<"stranger@localhost">>,
              Msg = amp_message_to(StrangerJid, [{deliver, none, error}],
                                   <<"This cannot possibly succeed">>),
              %% when
              client_sends_message(Alice, Msg),

              % then
              client_receives_amp_error(Alice, StrangerJid, {deliver, none, error}, <<"undefined-condition">>)
      end).

error_deliver_doesnt_apply_test(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}, {bob, 1}],
      fun(Alice,Bob) ->
              %% given
              Msg = amp_message_to(Bob, [{deliver, none, error}],
                                   <<"Hello, Bob!">>),
              %% when
              client_sends_message(Alice, Msg),

              % then
              client_receives_message(Bob, <<"Hello, Bob!">>),
              client_receives_nothing(Alice)
      end).


last_rule_applies_test(Config) ->
    escalus:fresh_story(
      Config, [{alice, 1}, {bob, 1}],
      fun(Alice,Bob) ->
              %% given
              BobsBareJid = escalus_client:short_jid(Bob),
              Msg = amp_message_to(BobsBareJid, [{deliver, none, error},
                                                 {deliver, stored, error},
                                                 {deliver, direct, notify}],
                                   <<"One of your resources needs to get this!">>),
              %% when
              client_sends_message(Alice, Msg),

              % then
              client_receives_notification(Alice, BobsBareJid, {deliver, direct, notify}),
              client_receives_message(Bob, <<"One of your resources needs to get this!">>)
      end).

notify_deliver_stored_test(Config) ->
    FreshConfig = escalus_fresh:create_users(Config, [{alice, 1}, {bob, 1}]),
    escalus:story(
      FreshConfig, [{alice, 1}],
      fun(Alice) ->
              %% given
              BobJid = escalus_users:get_jid(FreshConfig, bob),
              Msg = amp_message_to(BobJid, rules(Config, [{deliver, stored, notify}]),
                                   <<"A message in a bottle...">>),
              %% when
              client_sends_message(Alice, Msg),

              % then
              client_receives_notification(Alice, BobJid, {deliver, stored, notify}),
              client_receives_nothing(Alice)
      end),
    user_has_incoming_offline_message(FreshConfig, bob, <<"A message in a bottle...">>).

error_deliver_stored_test(Config) ->
    FreshConfig = escalus_fresh:create_users(Config, [{alice, 1}, {bob, 1}]),
    escalus:story(
      FreshConfig, [{alice, 1}],
      fun(Alice) ->
              %% given
              BobJid = escalus_users:get_jid(FreshConfig, bob),
              Msg = amp_message_to(BobJid, [{deliver, stored, error}],
                                   <<"A message in a bottle...">>),
              %% when
              client_sends_message(Alice, Msg),

              % then
              client_receives_amp_error(Alice, BobJid, {deliver, stored, error}, <<"undefined-condition">>),
              client_receives_nothing(Alice)
      end),
    user_has_no_incoming_offline_messages(FreshConfig, bob).

drop_deliver_stored_test(Config) ->
    FreshConfig = escalus_fresh:create_users(Config, [{alice, 1}, {bob, 1}]),
    escalus:story(
      FreshConfig, [{alice, 1}],
      fun(Alice) ->
              %% given
              BobJid = escalus_users:get_jid(FreshConfig, bob),
              Msg = amp_message_to(BobJid, [{deliver, stored, drop}],
                                   <<"A message in a bottle...">>),
              %% when
              client_sends_message(Alice, Msg),

              % then
              client_receives_nothing(Alice)
      end),
    user_has_no_incoming_offline_messages(FreshConfig, bob).

notify_deliver_none_instead_of_stored_filtered_by_privacy_test(Config) ->
    FreshConfig = escalus_fresh:create_users(Config, [{alice, 1}, {bob, 1}]),
    escalus:story(
      FreshConfig, [{bob, 1}],
      fun(Bob) ->
              %% given
              privacy_helper:set_and_activate(Bob, <<"deny_all_message">>),
              privacy_helper:set_default_list(Bob, <<"deny_all_message">>)
      end),
    escalus:story(
      FreshConfig, [{alice, 1}],
      fun(Alice) ->
              %% given
              BobJid = escalus_users:get_jid(FreshConfig, bob),
              Msg = amp_message_to(BobJid, [{deliver, none, notify}, {deliver, stored, notify}],
                                   <<"A message in a bottle...">>),
              %% when
              client_sends_message(Alice, Msg),

              % then
              client_receives_notification(Alice, BobJid, {deliver, none, notify})
      end).

%% Internal

user_has_no_incoming_offline_messages(FreshConfig, UserName) ->
    escalus:story(
      FreshConfig, [{UserName, 1}],
      fun(User) ->
              client_receives_nothing(User),
              case is_module_loaded(mod_mam) of
                  true -> client_has_no_mam_messages(User);
                  false -> ok
              end
      end).

user_has_incoming_offline_message(FreshConfig, UserName, MsgText) ->
    true = is_module_loaded(mod_mam) orelse is_module_loaded(mod_offline),
    {ok, Client} = escalus_client:start(FreshConfig, UserName, <<"new-session">>),
    escalus:send(Client, escalus_stanza:presence(<<"available">>)),
    case is_module_loaded(mod_offline) of
        true -> client_receives_message(Client, MsgText);
        false -> ok
    end,
    Presence = escalus:wait_for_stanza(Client),
    escalus:assert(is_presence, Presence),
    case is_module_loaded(mod_mam) of
        true -> client_has_mam_message(Client);
        false -> ok
    end,
    escalus_cleaner:clean(FreshConfig).

client_has_no_mam_messages(User) ->
    P = mam_helper:mam03_props(),
    escalus:send(User, mam_helper:stanza_archive_request(P, <<"q1">>)),
    Res = mam_helper:wait_archive_respond(P, User),
    mam_helper:assert_respond_size(0, Res).

client_has_mam_message(User) ->
    P = mam_helper:mam03_props(),
    escalus:send(User, mam_helper:stanza_archive_request(P, <<"q1">>)),
    Res = mam_helper:wait_archive_respond(P, User),
    mam_helper:assert_respond_size(1, Res).

setup_rules(Group, Config) when Group == offline_with_multiple_rules;
                                Group == mam_with_multiple_rules ->
    [{rules, [{deliver, none, notify},
              {deliver, direct, notify},
              {deliver, stored, notify}]} | Config];
setup_rules(_, Config) ->
    Config.

rules(Config, Default) ->
    case lists:keysearch(rules, 1, Config) of
	{value, {rules, Val}} -> Val;
	_ -> Default
    end.

ns_amp() ->
    <<"http://jabber.org/protocol/amp">>.

client_goes_offline(Client) ->
    escalus_client:stop(Client).

client_sends_message(Client, Msg) ->
    escalus_client:send(Client, Msg).

client_receives_amp_error(Client, Rules, AmpErrorKind) when is_list(Rules) ->
    Received = escalus_client:wait_for_stanza(Client),
    assert_amp_error(Client, Received, Rules, AmpErrorKind);
client_receives_amp_error(Client, Rule, AmpErrorKind) ->
    client_receives_amp_error(Client, [Rule], AmpErrorKind).

client_receives_amp_error(Client, IntendedRecipient, Rule, AmpErrorKind) ->
    Received = escalus_client:wait_for_stanza(Client),
    assert_amp_error_with_full_amp(Client, IntendedRecipient,
                                   Received, Rule, AmpErrorKind).

client_receives_generic_error(Client, Code, Type) ->
    Received = escalus_client:wait_for_stanza(Client),
    escalus:assert(fun contains_error/3, [Code, Type], Received).

client_receives_nothing(Client) ->
    timer:sleep(300),
    escalus_assert:has_no_stanzas(Client).

client_receives_message(Client, MsgText) ->
    Received = escalus_client:wait_for_stanza(Client),
    escalus:assert(is_chat_message, [MsgText], Received).

client_receives_notification(Client, IntendedRecipient, Rule) ->
    Msg = escalus_client:wait_for_stanza(Client),
    assert_notification(Client, IntendedRecipient, Msg, Rule).

disco_info(Config) ->
    Server = escalus_config:get_config(ejabberd_domain, Config),
    escalus_stanza:disco_info(Server).
disco_info_amp_node(Config) ->
    Server = escalus_config:get_config(ejabberd_domain, Config),
    escalus_stanza:disco_info(Server, ns_amp()).

assert_amp_error(Client, Response, Rules, AmpErrorKind) when is_list(Rules) ->
    ClientJID = escalus_client:full_jid(Client),
    Server = escalus_client:server(Client),
    Server = exml_query:attr(Response, <<"from">>),
    ClientJID = exml_query:attr(Response, <<"to">>),
    escalus:assert(fun contains_amp/5,
                   [amp_status_attr(AmpErrorKind), no_to_attr, no_from_attr, Rules],
                   Response),
    escalus:assert(fun contains_amp_error/3,
                   [AmpErrorKind, Rules],
                   Response);

assert_amp_error(Client, Response, Rule, AmpErrorKind) ->
    assert_amp_error(Client, Response, [Rule], AmpErrorKind).

assert_amp_error_with_full_amp(Client, IntendedRecipient, Response,
                               {C,V,A} = Rule, AmpErrorKind) ->
    ClientJID = escalus_client:full_jid(Client),
    RecipientJID = full_jid(IntendedRecipient),
    Server = escalus_client:server(Client),
    Server = exml_query:attr(Response, <<"from">>),
    ClientJID = exml_query:attr(Response, <<"to">>),
    escalus:assert(fun contains_amp/5,
                   [amp_status_attr(AmpErrorKind), RecipientJID, ClientJID, [Rule]],
                   Response),
    escalus:assert(fun contains_amp_error/3,
                   [AmpErrorKind, [Rule]],
                   Response).


assert_notification(Client, IntendedRecipient, Response, {_C,_V,A} = Rule) ->
    ClientJID = escalus_client:full_jid(Client),
    RecipientJID = full_jid(IntendedRecipient),
    Server = escalus_client:server(Client),
    Action = a2b(A),
    Server = exml_query:attr(Response, <<"from">>),
    ClientJID = exml_query:attr(Response, <<"to">>),
    escalus:assert(fun contains_amp/5,
                   [Action, RecipientJID, ClientJID, [Rule]],
                   Response).

assert_has_features(Response, Features) ->
    CheckF = fun(F) -> escalus:assert(has_feature, [F], Response) end,
    lists:foreach(CheckF, Features).

full_jid(#client{} = Client) ->
    escalus_client:full_jid(Client);
full_jid(B) when is_binary(B) ->
    B.

%% @TODO: Move me out to escalus_stanza %%%%%%%%%
%%%%%%%%% Element constructors %%%%%%%%%%%%%%%%%%
amp_message_to(To, Rules, MsgText) ->
    Msg0 = #xmlel{children=C} = escalus_stanza:chat_to(To, MsgText),
    Msg = escalus_stanza:set_id(Msg0, escalus_stanza:id()),
    Amp = amp_el(Rules),
    Msg#xmlel{children = C ++ [Amp]}.

amp_el([]) ->
    throw("cannot build <amp> with no rules!");
amp_el(Rules) ->
    #xmlel{name = <<"amp">>
          ,attrs = [{<<"xmlns">>, ns_amp()}]
          ,children = [ rule_el(R) || R <- Rules ]
          }.

rule_el({Condition, Value, Action}) ->
    check_rules(Condition, Value, Action),
    #xmlel{name = <<"rule">>
          ,attrs = [{<<"condition">>, a2b(Condition)}
                   ,{<<"value">>, a2b(Value)}
                   ,{<<"action">>, a2b(Action)}]}.

%% @TODO: Move me out to escalus_pred %%%%%%%%%%%%
%%%%%%%%% XML predicates %%%%% %%%%%%%%%%%%%%%%%%%
contains_amp(Status, To, From, ExpectedRules, Stanza) when is_list(ExpectedRules)->
    Amp = exml_query:subelement(Stanza, <<"amp">>),
    undefined =/= Amp andalso
        To == exml_query:attr(Amp, <<"to">>, no_to_attr) andalso
        From == exml_query:attr(Amp, <<"from">>, no_from_attr) andalso
        Status == exml_query:attr(Amp, <<"status">>, no_status_attr) andalso
        all_present([ rule_el(R) || R <- ExpectedRules ], exml_query:subelements(Amp, <<"rule">>)).

contains_amp_error(AmpErrorKind, Rules, Response) ->
    ErrorEl = exml_query:subelement(Response, <<"error">>),
    <<"modify">> == exml_query:attr(ErrorEl, <<"type">>)
        andalso
        amp_error_code(AmpErrorKind) == exml_query:attr(ErrorEl, <<"code">>)
        andalso
        undefined =/= (Marker = exml_query:subelement(ErrorEl, amp_error_marker(AmpErrorKind)))
        andalso
        ns_stanzas() == exml_query:attr(Marker, <<"xmlns">>)
        andalso
        undefined =/= (Container = exml_query:subelement(ErrorEl, amp_error_container(AmpErrorKind)))
        andalso
        all_present([ rule_el(R) || R <- Rules ], exml_query:subelements(Container, <<"rule">>)).

contains_error(Code, Type, Response) ->
    ErrorEl = exml_query:subelement(Response, <<"error">>),
    Type == exml_query:attr(ErrorEl, <<"type">>)
        andalso Code == exml_query:attr(ErrorEl, <<"code">>).

all_present(Needles, Haystack) ->
    list_and([ lists:member(Needle, Haystack)
               || Needle <- Needles ]).


list_and(List) ->
    lists:all(fun(X) -> X =:= true end, List).

ns_stanzas() ->
    <<"urn:ietf:params:xml:ns:xmpp-stanzas">>.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

check_rules(deliver, direct, notify) -> ok;
check_rules(deliver, stored, notify) -> ok;
check_rules(deliver, none, notify) -> ok;

check_rules(deliver, direct, error) -> ok;
check_rules(deliver, stored, error) -> ok;
check_rules(deliver, none, error) -> ok;

check_rules(deliver, stored, drop) -> ok;

check_rules('match-resource', any, notify) -> ok;
check_rules('match-resource', exact, notify) -> ok;
check_rules('match-resource', other, notify) -> ok;

check_rules(deliver, direct, alert) -> ok;       %% for testing unsupported rules
check_rules('expire-at', _binary, notify) -> ok; %% for testing unsupported conditions
check_rules(broken, rule, spec) -> ok;           %% for testing unacceptable rules
check_rules(also_broken, rule, spec) -> ok;      %% for testing unacceptable rules

check_rules(C,V,A) -> throw({illegal_amp_rule, {C, V, A}}).

a2b(B) when is_binary(B) -> B;
a2b(A) -> atom_to_binary(A, utf8).

%% Undefined-condition errors return a fully-fledged amp element with status=error
%% The other errors have 'thin' <amp>s with no status attribute
amp_status_attr(<<"undefined-condition">>) -> <<"error">>;
amp_status_attr(_)                         -> no_status_attr.

amp_error_code(<<"undefined-condition">>) -> <<"500">>;
amp_error_code(<<"not-acceptable">>) -> <<"405">>;
amp_error_code(<<"unsupported-actions">>) -> <<"400">>;
amp_error_code(<<"unsupported-conditions">>) -> <<"400">>.

amp_error_marker(<<"not-acceptable">>) -> <<"not-acceptable">>;
amp_error_marker(<<"unsupported-actions">>) -> <<"bad-request">>;
amp_error_marker(<<"unsupported-conditions">>) -> <<"bad-request">>;
amp_error_marker(<<"undefined-condition">>) -> <<"undefined-condition">>.

amp_error_container(<<"not-acceptable">>) -> <<"invalid-rules">>;
amp_error_container(<<"unsupported-actions">>) -> <<"unsupported-actions">>;
amp_error_container(<<"unsupported-conditions">>) -> <<"unsupported-conditions">>;
amp_error_container(<<"undefined-condition">>) -> <<"failed-rules">>.

is_odbc_enabled() ->
    case escalus_ejabberd:rpc(ejabberd_odbc, sql_transaction, [?DOMAIN, fun erlang:yield/0]) of
        {atomic, _} -> true;
        _ -> false
    end.

is_module_loaded(Mod) ->
    escalus_ejabberd:rpc(gen_mod, is_loaded, [?DOMAIN, Mod]).

required_modules(basic) ->
    mam_modules(off) ++ offline_modules(off);
required_modules(G) when G == mam;
                         G == mam_with_multiple_rules ->
    mam_modules(on) ++ offline_modules(off);
required_modules(G) when G == offline;
                         G == offline_with_multiple_rules ->
    mam_modules(off) ++ offline_modules(on);
required_modules(G) when G == mam_and_offline;
                         G == mam_and_offline_with_multiple_rules ->
    mam_modules(on) ++ offline_modules(on).

offline_modules(on) ->
    [{mod_offline, [{access_max_user_messages, max_user_offline_messages}]}];
offline_modules(off) ->
    [{mod_offline, stopped},
     {mod_offline_stub, []}].

mam_modules(on) ->
    [{mod_mam_odbc_user, [pm]},
     {mod_mam_odbc_prefs, [pm]},
     {mod_mam_odbc_arch, [pm]},
     {mod_mam, []}];
mam_modules(off) ->
    [{mod_mam, stopped}].
