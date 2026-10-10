# interactor-multiplayer-fabric-meta

Elixir scripts that make a headset vendor's XR simulator the system OpenXR runtime and record the result as a smoke test.

## What it is for

Each script starts the simulator, activates it as the system OpenXR runtime, checks that the active runtime manifest points at it, and writes the outcome to the multiplayer-fabric test database. One script is for macOS and one is for Windows.

## Build and run

    elixir activate_smoke_test.exs

On Windows, run `activate_smoke_test_windows.exs` the same way from an elevated shell. The simulator is installed separately.

## Licence

MIT. See [LICENSE](LICENSE).
