-module(bridge_test).
-export([load/1, run/1, operation/1]).
-nifs([operation/1]).

load(Path) -> erlang:load_nif(Path, 0).

run(reader_lifetime) ->
    ok = operation(reader_register),
    erlang:garbage_collect(),
    0 = operation(reader_destroyed),
    ok = operation(reader_unregister),
    wait_destroyed(1);
run(reader_replacement) ->
    ok = operation(reader_register),
    ok = operation(reader_register),
    wait_destroyed(1),
    ok = operation(reader_unregister),
    wait_destroyed(2);
run(Name) -> operation(Name).

operation(_) -> erlang:nif_error(undef).

wait_destroyed(Count) ->
    case operation(reader_destroyed) of
        Count -> ok;
        _ -> receive after 1 -> wait_destroyed(Count) end
    end.
