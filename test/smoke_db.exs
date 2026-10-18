# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
#
# Checks each smoke-test script's database half without the simulator:
# compiles the script's module, opens its database, writes two runs and
# reads them back, then plants a missing weftfdb extension, which must
# be an error. With SMOKE_WEFTFDB_EXTENSION set, the database is a
# weft_fdb one in FoundationDB.
#
#   elixir test/smoke_db.exs activate_smoke_test.exs activate_smoke_test_windows.exs
Mix.install([{:exqlite, "~> 0.42"}, {:jason, "~> 1.4"}])

extension = System.get_env("SMOKE_WEFTFDB_EXTENSION")

for file <- System.argv() do
  src =
    File.read!(file)
    |> String.replace(~r/^Mix\.install\(\[.*?\]\)\n/ms, "")
    |> String.replace(~r/^MetaXRSmokeTest[\w.]*\.run\(\)\s*$/m, "")
    |> String.replace(~r/defmodule MetaXRSmokeTest[\w.]*/, "defmodule Harness#{:erlang.phash2(file)}")
    # Both scripts' modules share one load key: the extension loads once per process.
    |> String.replace("{__MODULE__, :weftfdb, path}", "{:smoke_weftfdb, path}")
    |> String.replace(~r/defp (open_db|ensure_schema!|record)(?=[\s(])/, "def \\1")

  n = System.unique_integer([:positive])

  db =
    if extension,
      do: "file:smoke_test_#{n}.v1?vfs=weft_fdb",
      else: Path.join(System.tmp_dir!(), "smoke-#{n}.sqlite3")

  System.put_env("SMOKE_DB", db)
  [{mod, _}] = Code.compile_string(src, file)
  IO.puts(:stderr, "DIAG compiled #{file}, opening #{db}")
  {:ok, conn} = mod.open_db()
  IO.puts(:stderr, "DIAG opened")
  :ok = mod.ensure_schema!(conn)
  IO.puts(:stderr, "DIAG schema")
  mod.record(conn, "verify_runtime", :ok, "detail")
  mod.record(conn, "smoke_test", "ok", nil)
  {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT step, status, detail FROM smoke_test_runs ORDER BY id")
  {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, stmt)
  Exqlite.Sqlite3.close(conn)
  IO.puts("#{Path.basename(file)} (#{db}): #{inspect(rows)}")
  true = rows == [["verify_runtime", "ok", "detail"], ["smoke_test", "ok", nil]]

  System.put_env("SMOKE_WEFTFDB_EXTENSION", "/nonexistent/weftfdb")
  System.delete_env("SMOKE_DB")
  {:error, _} = mod.open_db()
  if extension, do: System.put_env("SMOKE_WEFTFDB_EXTENSION", extension), else: System.delete_env("SMOKE_WEFTFDB_EXTENSION")
  IO.puts("#{Path.basename(file)}: missing extension is an error, as planted")
end
IO.puts(:stderr, "DIAG done")
