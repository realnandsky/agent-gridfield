# Agent Gridfield

Write the app UI, project documentation, and release materials in English.

## Build and release

Run tests with `Scripts/test.sh` and build the macOS app with `Scripts/build-app.sh`. The default build output is `dist/GridWorld.app`.

Combine `GridWorldVersionPrefix` and `CFBundleShortVersionString` from `Bundle/Info.plist` to form the release label (for example, `labdev1.15.0`). From the directory containing the app, create a fresh versioned archive:

```sh
ditto -c -k --norsrc --noextattr --noqtn --keepParent GridWorld.app GridWorld-macOS-labdev1.15.0.zip
```

Verify the extracted app with `codesign --verify --strict`. Attach the ZIP to the GitHub Release for the matching tag and compare the uploaded SHA-256 with the local archive. Keep credentials, debug exports, and build outputs out of source control.

## Model capabilities

- Describe the available tools, parameters, effects, and system boundaries. Leave task strategy, tool timing, and generalizing from examples to the model.
- For example, memory instructions explain what context persists between turns and how notebook text persists or is replaced. The model decides what to record and when.

## Live debugging

For runtime debugging, start with the [live debug exports](docs/reference.md#live-debug-exports). Match the process ID, timestamp, and goal to the session under investigation. Read `state.json` and `events.jsonl` before using the window. Use screenshots for layout, drawing, and animation checks.
