#!/usr/bin/env escript
%%! -noshell
%%
%% sqlite.escript — an interactive SQLite REPL running on the BEAM.
%%
%% `sqlite3.beam` is the SQLite 3.51 amalgamation compiled from WebAssembly to
%% Core Erlang / BEAM by 2core. It has NO native code and NO NIFs — it is pure
%% BEAM bytecode driving the WASM linear memory as an Erlang binary. `ebin/`
%% holds the handful of 2core runtime modules its generated code calls (memory,
%% traps, numerics, the per-instance state cell).
%%
%% Usage:
%%   ./sqlite.escript                    # interactive REPL (a demo db is preloaded)
%%   ./sqlite.escript "SELECT 6*7;"      # one-shot: run SQL and exit
%%   echo "SELECT sqlite_version();" | ./sqlite.escript
%%
%% The database is in-memory and fresh on every launch.
%%
%% REPL dot-commands:  .tables   .schema   .help   .quit / .exit / Ctrl-D

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

    case Args of
        [Sql | _] ->
            %% one-shot mode: run the SQL and exit
            run_script(Db, Sql);
        [] ->
            %% interactive mode: preload the demo db, then drop into the REPL
            seed_demo(Db),
            banner(Db),
            repl(Db)
    end,
    ?MOD:sqlite3_close(Db),
    ok.

%% ================= the REPL =================

banner(Db) ->
    io:format("~n  SQLite ~s on the BEAM — pure WASM→BEAM, no NIFs.~n",
              [rd_cstr(?MOD:sqlite3_libversion())]),
    io:format("  in-memory demo database loaded:~n~n"),
    run_script(Db, "SELECT artist.name AS artist, album.title AS album "
                   "FROM album JOIN artist ON artist.id=album.artist_id "
                   "ORDER BY album.id;"),
    io:format("  Type SQL (a trailing ; is optional). "
              "Dot-commands: .tables  .schema  .help  .quit~n").

repl(Db) ->
    case io:get_line("sqlite> ") of
        eof         -> io:format("~n");
        {error, _}  -> ok;
        Line0 ->
            case string:trim(Line0) of
                ""       -> repl(Db);
                ".quit"  -> ok;
                ".exit"  -> ok;
                ".help"  -> help(), repl(Db);
                ".tables" ->
                    run_script(Db, "SELECT name FROM sqlite_master "
                                   "WHERE type='table' ORDER BY name;"),
                    repl(Db);
                ".schema" ->
                    run_script(Db, "SELECT sql FROM sqlite_master "
                                   "WHERE sql IS NOT NULL ORDER BY rowid;"),
                    repl(Db);
                Line ->
                    %% Never let a bad query kill the REPL.
                    try run_script(Db, Line)
                    catch K:E -> io:format("  error: ~p:~p~n~n", [K, E]) end,
                    repl(Db)
            end
    end.

help() ->
    io:format("  .tables         list tables~n"
              "  .schema         show CREATE statements~n"
              "  .help           this help~n"
              "  .quit / .exit   leave (or press Ctrl-D)~n"
              "  anything else   is run as SQL~n~n").

%% ================= demo data =================

seed_demo(Db) ->
    run_silent(Db,
        "CREATE TABLE artist(id INTEGER PRIMARY KEY, name TEXT);"
        "CREATE TABLE album(id INTEGER PRIMARY KEY, title TEXT, artist_id INT);"
        %% The Ariston goes in first so its album leads the listing.
        "INSERT INTO artist(name) VALUES ('The Ariston'),('Microwave'),('Headache');"
        "INSERT INTO album(title,artist_id) VALUES "
        "  ('Honey, I''d Lie To You', 1),"
        "  ('Much Love', 2),"
        "  ('The Head Hurts but the Heart Knows the Truth', 3);").

%% ================= statement execution =================

%% run every statement in Sql, printing SELECT results (prepare/step/finalize, following pzTail)
run_script(Db, Sql) -> run_from(Db, wr_cstr(Sql), true).

%% run for side effects only, printing nothing (used to seed the demo quietly)
run_silent(Db, Sql) -> run_from(Db, wr_cstr(Sql), false).

run_from(Db, CurPtr, Print) ->
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
                            case Print of
                                true  -> print_stmt(Db, Stmt);
                                false -> _ = ?MOD:sqlite3_step(Stmt)
                            end,
                            ?MOD:sqlite3_finalize(Stmt),
                            run_from(Db, Tail, Print)
                    end;
                Rc ->
                    io:format("  error rc=~p: ~s~n~n",
                              [Rc, rd_cstr(?MOD:sqlite3_errmsg(Db))])
            end
    end.

%% step a prepared statement, printing header + rows for a SELECT
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

%% read one column as text ("NULL" when the value is SQL NULL)
col_text(Stmt, I) ->
    case ?MOD:sqlite3_column_text(Stmt, I) of
        0 -> "NULL";
        P -> rd_cstr(P)
    end.

%% ================= linear-memory + allocation helpers =================

open_mem() ->
    FnP  = wr_cstr(":memory:"),
    PpDb = alloc(4),
    0 = ?MOD:sqlite3_open(FnP, PpDb),
    rd_i32(PpDb).

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
