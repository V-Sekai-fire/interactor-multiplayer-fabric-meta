# interactor-multiplayer-fabric-meta

Elixir scripts that make a headset vendor's XR simulator the system OpenXR runtime and record the result as a smoke test.

## What it is for

Each script starts the simulator, activates it as the system OpenXR runtime, checks that the active runtime manifest points at it, and writes the outcome to the multiplayer-fabric test database. One script is for macOS and one is for Windows.

## Build and run

    elixir activate_smoke_test.exs

On macOS the simulator's `MetaXRSimulator.app` bundle must sit beside the script, which runs the bundle's activation script with `sudo`. On Windows, run `activate_smoke_test_windows.exs` the same way from an elevated shell; it looks for the simulator beside the script and under `Program Files`.

Both scripts need a reachable test database, named by `TEST_DATABASE_URL` or the `TEST_DB_*` variables, or by certificates under `../multiplayer-fabric-hosting/certs/crdb`.

## Licence

The repository states no licence.
