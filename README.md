# sqlite.beam

sqlite, fully ported to the BEAM via [2core](https://github.com/hiett/2core)

in this build, no NIFs are used. this is pure generated core erlang compiled to .beam

sqlite.beam was produced from building sqlite to wasm (with a few tweaks to deal with 2core's current limitations)
and then running it through 2core

2core converts wasm (and soon other frontends) instructions to core erlang code.

## how to try it out

have an elixir/erlang/gleam toolchain installed, and simply run:

`escript sqlite.escript`

this will pre-seed an in memory database with a couple tables and give you an sqlite repl.

if you don't want to run it, the output will look like this:

```
scotthiett@Scotts-MacBook-Pro sqlite.beam % escript sqlite.escript

  SQLite 3.51.0 on the BEAM — pure WASM→BEAM, no NIFs.
  in-memory demo database loaded:

  artist | album
  --------------
  The Ariston | Honey, I'd Lie To You
  Microwave | Much Love
  Headache | The Head Hurts but the Heart Knows the Truth

  Type SQL (a trailing ; is optional). Dot-commands: .tables  .schema  .help  .quit
sqlite> SELECT * FROM album
  id | title | artist_id
  ----------------------
  1 | Honey, I'd Lie To You | 1
  2 | Much Love | 2
  3 | The Head Hurts but the Heart Knows the Truth | 3

sqlite> SELECT * FROM album JOIN artist ON album.artist_id = artist.id
  id | title | artist_id | id | name
  ----------------------------------
  1 | Honey, I'd Lie To You | 1 | 1 | The Ariston
  2 | Much Love | 2 | 2 | Microwave
  3 | The Head Hurts but the Heart Knows the Truth | 3 | 3 | Headache

sqlite>
```

## other notes

the 2core ir is in `sqlite.ir`. the erlang core file is 246MB, so it's gzipped as `sqlite.core.gz`