# Agent Gridfield delivery

After each change to GridWorld, compile the macOS app with `Scripts/build-app.sh`, package `GridWorld.app` in a versioned ZIP under the workspace's `outputs` directory, and include a link to the ZIP in the final response. Verify the archive and bundled code signature before handing it over.

Prefix release labels with `labdev`, as in `labdev1.9.0` and `GridWorld-macOS-labdev1.9.0.zip`. Use `GridWorldVersionPrefix` and the numeric `CFBundleShortVersionString` from `Bundle/Info.plist` to form the label.

For runtime debugging, start with the [live debug exports](docs/reference.md#live-debug-exports). Match the process ID, timestamp, and goal to the session under investigation. Read `state.json` and `events.jsonl` before using the window. Use screenshots for layout, drawing, and animation checks.
