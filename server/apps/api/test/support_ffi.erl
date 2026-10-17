%% Test-only helper: build a value once per test run (the shared database
%% pool) under a global lock, since gleeunit runs tests concurrently.
-module(support_ffi).
-export([cached/1]).

cached(Make) ->
    global:trans({libarrie_test_app, self()}, fun() ->
        case persistent_term:get(libarrie_test_app, undefined) of
            undefined ->
                Value = Make(),
                persistent_term:put(libarrie_test_app, Value),
                Value;
            Value -> Value
        end
    end).
