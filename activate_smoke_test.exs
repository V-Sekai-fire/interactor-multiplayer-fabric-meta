#!/usr/bin/env elixir
# Activate Meta XR Simulator as the system OpenXR runtime and record the
# result in SQLite (in FoundationDB when SMOKE_WEFTFDB_EXTENSION is set).
#
# Usage (from multiplayer-fabric-meta/):
#   elixir activate_smoke_test.exs
#
# Database: SMOKE_DB, SMOKE_WEFTFDB_EXTENSION (see open_db/0).

Mix.install([
  {:exqlite, "~> 0.42"},
  {:jason, "~> 1.4"}
])

defmodule MetaXRSmokeTest do
  @moduledoc """
  HTN-style smoke test for Meta XR Simulator activation on macOS.

  Steps (plan):
    1. ensure_app_running  – launch MetaXRSimulator.app if not running
    2. activate_runtime    – sudo bash activate_simulator.sh
    3. verify_runtime      – confirm active_runtime.json points to Meta XR
    4. record_result       – persist outcome to the smoke_test_runs table
  """

  @app_bundle Path.expand("MetaXRSimulator.app", Path.dirname(__ENV__.file))
  @activate_sh Path.join([@app_bundle, "Contents/Resources/MetaXRSimulator/activate_simulator.sh"])
  @runtime_json "/usr/local/share/openxr/1/active_runtime.json"


  # ── DB ─────────────────────────────────────────────────────────────────────
  #
  # SQLite. SMOKE_DB names the database. With SMOKE_WEFTFDB_EXTENSION set
  # (datasource-store's weftfdb), the default is file:smoke_test.v1?vfs=weft_fdb,
  # whose pages live in FoundationDB; otherwise smoke_test.sqlite3 beside this script.

  defp open_db do
    extension = System.get_env("SMOKE_WEFTFDB_EXTENSION")

    db =
      System.get_env("SMOKE_DB") ||
        if(extension,
          do: "file:smoke_test.v1?vfs=weft_fdb",
          else: Path.expand("smoke_test.sqlite3", Path.dirname(__ENV__.file))
        )

    with :ok <- load_extension(extension),
         {:ok, conn} <- Exqlite.Sqlite3.open(db) do
      {:ok, conn}
    end
  end

  defp load_extension(nil), do: :ok

  defp load_extension(path) do
    {:ok, tmp} = Exqlite.Sqlite3.open(":memory:")

    try do
      with :ok <- Exqlite.Sqlite3.enable_load_extension(tmp, true) do
        Exqlite.Sqlite3.execute(tmp, "SELECT load_extension('#{String.replace(path, "'", "''")}')")
      end
    after
      Exqlite.Sqlite3.close(tmp)
    end
  end

  defp ensure_schema!(conn) do
    :ok =
      Exqlite.Sqlite3.execute(conn, """
        CREATE TABLE IF NOT EXISTS smoke_test_runs (
          id      INTEGER PRIMARY KEY,
          run_at  TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
          step    TEXT NOT NULL,
          status  TEXT NOT NULL,
          detail  TEXT
        )
      """)
  end

  defp record(conn, step, status, detail) do
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(
        conn,
        "INSERT INTO smoke_test_runs (step, status, detail) VALUES (?1, ?2, ?3)"
      )

    :ok = Exqlite.Sqlite3.bind(stmt, [step, to_string(status), detail])
    :done = Exqlite.Sqlite3.step(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)
  end

  # ── Steps ──────────────────────────────────────────────────────────────────

  defp ensure_app_running(conn) do
    case System.cmd("pgrep", ["-x", "MetaXRSimulator"], stderr_to_stdout: true) do
      {_, 0} ->
        IO.puts("  [ok] MetaXRSimulator already running")
        record(conn, "ensure_app_running", "ok", "already running")

      {_, _} ->
        IO.puts("  [..] Launching #{@app_bundle}")
        {out, code} = System.cmd("open", [@app_bundle], stderr_to_stdout: true)
        if code != 0, do: raise("Failed to launch: #{out}")
        Process.sleep(3_000)
        record(conn, "ensure_app_running", "ok", "launched")
    end
  end

  defp activate_runtime(conn) do
    IO.puts("  [..] Running activate_simulator.sh (sudo)")
    {out, code} = System.cmd("sudo", ["bash", @activate_sh], stderr_to_stdout: true)
    detail = String.trim(out)
    if code != 0, do: raise("activate_simulator.sh failed: #{detail}")
    IO.puts("  [ok] #{detail}")
    record(conn, "activate_runtime", "ok", detail)
  end

  defp verify_runtime(conn) do
    IO.puts("  [..] Verifying #{@runtime_json}")
    case File.read(@runtime_json) do
      {:ok, content} when is_binary(content) ->
        if String.contains?(content, "Meta") do
          IO.puts("  [ok] Runtime points to Meta XR Simulator")
          record(conn, "verify_runtime", "ok", String.trim(content))
        else
          record(conn, "verify_runtime", "error", content)
          raise "active_runtime.json does not reference Meta XR Simulator"
        end

      {:error, reason} ->
        record(conn, "verify_runtime", "error", inspect(reason))
        raise "Cannot read #{@runtime_json}: #{inspect(reason)}"
    end
  end

  # ── Entry point ────────────────────────────────────────────────────────────

  def run do
    IO.puts("=== Meta XR Simulator smoke test ===")
    {:ok, conn} = open_db()
    ensure_schema!(conn)

    [&ensure_app_running/1, &activate_runtime/1, &verify_runtime/1]
    |> Enum.each(& &1.(conn))

    record(conn, "smoke_test", "ok", "all steps passed")
    IO.puts("\n=== PASS: all steps recorded to smoke_test_runs ===")
    Exqlite.Sqlite3.close(conn)
  end
end

MetaXRSmokeTest.run()
