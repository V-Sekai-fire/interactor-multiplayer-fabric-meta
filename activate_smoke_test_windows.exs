#!/usr/bin/env elixir
# Activate Meta XR Simulator as the system OpenXR runtime on Windows and
# record the result in SQLite (in FoundationDB when SMOKE_WEFTFDB_EXTENSION is set).
#
# Usage (from multiplayer-fabric-meta/, elevated PowerShell):
#   elixir activate_smoke_test_windows.exs
#
# Requires: Meta XR Simulator installed (from developers.meta.com).
# The simulator's runtime manifest JSON must exist at:
#   <install_dir>\meta_openxr_simulator.json
#
# Database: SMOKE_DB, SMOKE_WEFTFDB_EXTENSION (see open_db/0).

Mix.install([
  {:exqlite, "~> 0.42"},
  {:jason, "~> 1.4"}
])

defmodule MetaXRSmokeTest.Windows do
  @moduledoc """
  HTN-style smoke test for Meta XR Simulator activation on Windows.

  Steps (plan):
    1. find_simulator      – locate MetaXRSimulator.exe install path
    2. ensure_app_running  – launch MetaXRSimulator.exe if not running
    3. activate_runtime    – set HKLM OpenXR ActiveRuntime registry key
    4. verify_runtime      – confirm registry points to Meta XR Simulator
    5. record_result       – persist outcome to the smoke_test_runs table
  """

  @simulator_exe "MetaXRSimulator.exe"

  @candidate_dirs (
    [Path.expand("MetaXRSimulator", Path.dirname(__ENV__.file))] ++
    (for v <- ["v201.0", "v200.0", "v199.0", ""],
     do: "C:/Program Files/MetaXRSimulator/#{v}" |> String.trim_trailing("/")) ++
    ["C:/Program Files/Meta/Meta XR Simulator",
     "C:/Program Files (x86)/Meta/Meta XR Simulator"]
  )



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
         {:ok, conn} <- Exqlite.Sqlite3.open(db),
         :ok <- pragmas(conn, extension) do
      {:ok, conn}
    end
  end

  # A weft_fdb database is opened the way zone-backend opens one: the
  # rollback journal in memory and the database held by this connection.
  defp pragmas(_conn, nil), do: :ok

  defp pragmas(conn, _extension) do
    Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode = MEMORY; PRAGMA locking_mode = EXCLUSIVE")
  end

  defp load_extension(nil), do: :ok

  # The weft_fdb VFS registers process-wide and starts FoundationDB's network
  # thread, which can start only once per process, so it is loaded once.
  defp load_extension(path) do
    key = {__MODULE__, :weftfdb, path}

    if :persistent_term.get(key, false) do
      :ok
    else
      {:ok, tmp} = Exqlite.Sqlite3.open(":memory:")

      try do
        with :ok <- Exqlite.Sqlite3.enable_load_extension(tmp, true),
             :ok <-
               Exqlite.Sqlite3.execute(tmp, "SELECT load_extension('#{String.replace(path, "'", "''")}')") do
          :persistent_term.put(key, true)
          :ok
        end
      after
        Exqlite.Sqlite3.close(tmp)
      end
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

  defp record(nil, _step, _status, _detail), do: :ok
  defp record(conn, step, status, detail) do
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(
        conn,
        "INSERT INTO smoke_test_runs (step, status, detail) VALUES (?1, ?2, ?3)"
      )

    :ok = Exqlite.Sqlite3.bind(stmt, [step, to_string(status), detail])
    # fetch_all, not step: it runs on a dirty scheduler, where a weft_fdb
    # write can block on FoundationDB.
    {:ok, []} = Exqlite.Sqlite3.fetch_all(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)
  end

  # ── Registry helpers ───────────────────────────────────────────────────────

  defp read_registry(path, value_name) do
    {out, code} = System.cmd("reg", [
      "query", "HKLM\\#{path}", "/v", value_name
    ], stderr_to_stdout: true)

    if code == 0 do
      case Regex.run(~r/REG_SZ\s+(.+)/, out) do
        [_, val] -> {:ok, String.trim(val)}
        _        -> {:error, "could not parse reg output: #{out}"}
      end
    else
      {:error, String.trim(out)}
    end
  end

  defp write_registry(path, value_name, value) do
    {out, code} = System.cmd("reg", [
      "add", "HKLM\\#{path}", "/v", value_name,
      "/t", "REG_SZ", "/d", value, "/f"
    ], stderr_to_stdout: true)

    if code == 0, do: :ok, else: {:error, String.trim(out)}
  end

  # ── Steps ──────────────────────────────────────────────────────────────────

  defp find_simulator(conn) do
    IO.puts("  [..] Searching for #{@simulator_exe}")

    install_dir = Enum.find(@candidate_dirs, fn dir ->
      File.exists?(Path.join(dir, @simulator_exe))
    end)

    if install_dir do
      IO.puts("  [ok] Found at #{install_dir}")
      record(conn, "find_simulator", "ok", install_dir)
      install_dir
    else
      detail = "Searched: #{inspect(@candidate_dirs)}"
      record(conn, "find_simulator", "error", detail)
      raise "#{@simulator_exe} not found. #{detail}"
    end
  end

  defp find_runtime_json(install_dir) do
    candidates = [
      Path.join(install_dir, "meta_openxr_simulator.json"),
      Path.join(install_dir, "meta_openxr_simulator_64.json")
    ]

    Enum.find(candidates, &File.exists?/1) ||
      raise "No runtime manifest JSON in #{install_dir}. Expected one of: #{inspect(candidates)}"
  end

  defp ensure_app_running(conn, install_dir) do
    {out, _code} = System.cmd("tasklist", ["/FI", "IMAGENAME eq #{@simulator_exe}"],
                              stderr_to_stdout: true)

    if String.contains?(out, @simulator_exe) do
      IO.puts("  [ok] #{@simulator_exe} already running")
      record(conn, "ensure_app_running", "ok", "already running")
    else
      exe = Path.join(install_dir, @simulator_exe)
      IO.puts("  [..] Launching #{exe}")
      {launch_out, code} = System.cmd("cmd", ["/c", "start", "", exe],
                                       stderr_to_stdout: true)
      if code != 0, do: raise("Failed to launch: #{launch_out}")
      Process.sleep(5_000)
      record(conn, "ensure_app_running", "ok", "launched")
    end
  end

  defp activate_runtime(conn, install_dir) do
    activate_ps1 = Path.join(install_dir, "activate_simulator.ps1")

    if File.exists?(activate_ps1) do
      IO.puts("  [..] Running #{activate_ps1}")
      {out, code} = System.cmd("powershell", [
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", activate_ps1, "-MessageTime", "0"
      ], stderr_to_stdout: true)
      detail = String.trim(out)
      if code != 0, do: raise("activate_simulator.ps1 failed: #{detail}")
      IO.puts("  [ok] #{detail}")
      record(conn, "activate_runtime", "ok", detail)
    else
      runtime_json = find_runtime_json(install_dir)
      IO.puts("  [..] Setting OpenXR ActiveRuntime → #{runtime_json}")

      case write_registry("SOFTWARE\\Khronos\\OpenXR\\1", "ActiveRuntime", runtime_json) do
        :ok ->
          IO.puts("  [ok] Registry updated")
          record(conn, "activate_runtime", "ok", runtime_json)
        {:error, reason} ->
          record(conn, "activate_runtime", "error", reason)
          raise "Registry write failed (run as admin?): #{reason}"
      end
    end
  end

  defp verify_runtime(conn) do
    IO.puts("  [..] Verifying HKLM\\SOFTWARE\\Khronos\\OpenXR\\1\\ActiveRuntime")

    case read_registry("SOFTWARE\\Khronos\\OpenXR\\1", "ActiveRuntime") do
      {:ok, value} ->
        if String.contains?(String.downcase(value), "meta") do
          IO.puts("  [ok] ActiveRuntime → #{value}")
          record(conn, "verify_runtime", "ok", value)
        else
          record(conn, "verify_runtime", "error", value)
          raise "ActiveRuntime does not reference Meta XR Simulator: #{value}"
        end

      {:error, reason} ->
        record(conn, "verify_runtime", "error", reason)
        raise "Cannot read ActiveRuntime: #{reason}"
    end
  end

  # ── Entry point ────────────────────────────────────────────────────────────

  def run do
    IO.puts("=== Meta XR Simulator smoke test (Windows) ===")

    conn =
      case open_db() do
        {:ok, c} ->
          ensure_schema!(c)
          IO.puts("  [ok] Opened the smoke-test database")
          c

        {:error, reason} ->
          IO.puts("  [warn] No database (#{inspect(reason)}); results will not be persisted")
          nil
      end

    install_dir = find_simulator(conn)
    ensure_app_running(conn, install_dir)
    activate_runtime(conn, install_dir)
    verify_runtime(conn)

    if conn do
      record(conn, "smoke_test", "ok", "all steps passed")
      Exqlite.Sqlite3.close(conn)
    end
    IO.puts("\n=== PASS ===")
  end
end

MetaXRSmokeTest.Windows.run()
