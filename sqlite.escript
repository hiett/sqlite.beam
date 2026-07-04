#!/usr/bin/env escript
%%! -noshell
%%
%% sqlite.escript — run real SQLite on the BEAM.
%%
%% `sqlite3.beam` is the SQLite 3.51 amalgamation compiled from WebAssembly to
%% Core Erlang / BEAM by 2core (https://github.com/…/2core). It has NO native
%% code and NO NIFs — it is pure BEAM bytecode running the WASM linear memory as
%% an Erlang binary. `ebin/` holds the handful of 2core runtime modules its
%% generated code calls (memory, traps, numerics, the per-instance state cell).
%%
%% Usage (from anywhere):
%%   ./sqlite.escript                              # built-in demo
%%   ./sqlite.escript "SELECT sqlite_version();"   # any SQL you like
%%   escript sqlite.escript "SELECT 6*7;"
%%
%% The database is in-memory and fresh on every run.

-define(MOD, 'twocore@wasm@sqlite3_malloc').
-define(MEM, 'twocore@runtime@rt_mem').

main(Args) ->
    %% Locate our own directory so the script runs from any CWD.
    Base = filename:dirname(filename:absname(escript:script_name())),
    true = code:add_pathz(filename:join(Base, "ebin")),
    {ok, Bin} = file:read_file(filename:join(Base, "sqlite3.beam")),
    {module, _} = code:load_binary(?MOD, "sqlite3.beam", Bin),

    ?MOD:instantiate(),                 %% seed this process's instance cell (memory/globals/table)
    0 = ?MOD:sqlite3_wasm_bootstrap(),  %% sqlite3_initialize + the import-free VFS/PRNG/clock

    Db = open_mem(),
    Sql = case Args of
        [S | _] -> S;
        []      -> demo_sql()
    end,
    run_script(Db, Sql),
    ?MOD:sqlite3_close(Db),
    ok.

%% ---- the demo: build a tiny schema, list the tables, then read the rows back ----
demo_sql() ->
    "CREATE TABLE artist(id INTEGER PRIMARY KEY, name TEXT);"
    "CREATE TABLE album(id INTEGER PRIMARY KEY, title TEXT, artist_id INT);"
    "INSERT INTO artist(name) VALUES ('Aphex Twin'),('Boards of Canada'),('Autechre');"
    "INSERT INTO album(title,artist_id) VALUES ('Drukqs',1),('Music Has the Right',2),('Amber',3);"
    "SELECT name AS tables FROM sqlite_master WHERE type='table' ORDER BY name;"
    "SELECT artist.name, album.title FROM album JOIN artist ON artist.id=album.artist_id ORDER BY artist.name;".

%% ---- open an in-memory database, returning the sqlite3* handle ----
open_mem() ->
    FnP  = wr_cstr(":memory:"),
    PpDb = alloc(4),
    0 = ?MOD:sqlite3_open(FnP, PpDb),
    rd_i32(PpDb).

%% ---- run every statement in Sql (prepare/step/finalize, following pzTail) ----
run_script(Db, Sql) ->
    run_from(Db, wr_cstr(Sql)).

run_from(Db, CurPtr) ->
    case rd_cstr(CurPtr) of
        "" -> ok;                          %% nothing left but the trailing NUL
        _  ->
            PpStmt = alloc(4),
            PzTail = alloc(4),
            case ?MOD:sqlite3_prepare_v2(Db, CurPtr, 16#FFFFFFFF, PpStmt, PzTail) of
                0 ->
                    Stmt = rd_i32(PpStmt),
                    Tail = rd_i32(PzTail),
                    case Stmt of
                        0 -> ok;           %% only whitespace/comments remained
                        _ ->
                            print_stmt(Db, Stmt),
                            ?MOD:sqlite3_finalize(Stmt),
                            run_from(Db, Tail)
                    end;
                Rc ->
                    io:format("prepare error rc=~p: ~s~n", [Rc, rd_cstr(?MOD:sqlite3_errmsg(Db))])
            end
    end.

%% ---- step a prepared statement, printing header + rows for a SELECT ----
print_stmt(Db, Stmt) ->
    NCol = ?MOD:sqlite3_column_count(Stmt),
    case NCol of
        0 ->
            _ = ?MOD:sqlite3_step(Stmt),
            io:format("  (ok — ~p row(s) changed)~n~n", [?MOD:sqlite3_changes(Db)]);
        _ ->
            Headers = [rd_cstr(?MOD:sqlite3_column_name(Stmt, I)) || I <- lists:seq(0, NCol-1)],
            Head = string:join(Headers, " | "),
            io:format("  ~s~n  ~s~n", [Head, lists:duplicate(length(Head), $-)]),
            step_rows(Stmt, NCol),
            io:format("~n")
    end.

step_rows(Stmt, NCol) ->
    case ?MOD:sqlite3_step(Stmt) of
        100 ->                             %% SQLITE_ROW
            Cols = [col_text(Stmt, I) || I <- lists:seq(0, NCol-1)],
            io:format("  ~s~n", [string:join(Cols, " | ")]),
            step_rows(Stmt, NCol);
        101 -> ok;                         %% SQLITE_DONE
        Other -> io:format("  step error rc=~p~n", [Other])
    end.

%% ---- read one column as text ("NULL" when the value is SQL NULL) ----
col_text(Stmt, I) ->
    case ?MOD:sqlite3_column_text(Stmt, I) of
        0 -> "NULL";
        P -> rd_cstr(P)
    end.

%% ================= linear-memory + allocation helpers =================

alloc(N) -> ?MOD:sqlite3_malloc(N).

%% write a NUL-terminated C string into freshly malloc'd memory; return its pointer
wr_cstr(S) ->
    B = iolist_to_binary(S),
    P = alloc(byte_size(B) + 1),
    {ok, _} = ?MEM:store_bytes(P, <<B/binary, 0>>, 0),
    P.

%% read a NUL-terminated C string out of linear memory at Ptr
rd_cstr(Ptr) -> rd_cstr(Ptr, []).
rd_cstr(Ptr, Acc) ->
    {ok, <<C>>} = ?MEM:load_bytes(Ptr, 0, 1),
    case C of
        0 -> lists:reverse(Acc);
        _ -> rd_cstr(Ptr + 1, [C | Acc])
    end.

%% read a little-endian 32-bit word (a pointer or int) out of linear memory
rd_i32(Ptr) ->
    {ok, <<V:32/little>>} = ?MEM:load_bytes(Ptr, 0, 4),
    V.
