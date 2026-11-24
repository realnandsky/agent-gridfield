# Agent Gridfield

A simple, beautiful open-source sandbox for AI agents.

Give an agent a goal and watch it gather resources, craft, and build in a small real-time grid world. The agent can design a blueprint, then let the game clear the site, gather materials, plan the build, and join adjacent walls. During a run, the world clock keeps going while the model thinks. Open Developer Tools to inspect its API requests, tool calls, notebook, and the maps it asks to see.

![The agent gathers materials and builds a house. Developer Tools shows the final tool call and the map sent to the agent.](docs/demo.gif)

*Recorded in the macOS app with scripted model responses.*

## Quick start

**macOS 14 or later.** The prebuilt app is for Apple Silicon (arm64).

1. Download the macOS ZIP from this repository’s Releases page, unzip it, and open `GridWorld.app`.
2. Open **Settings** (⌘,) and save your API key. The default configuration uses OpenAI with `gpt-5-mini`. You can also configure a Chat Completions-compatible endpoint with function tool support.
3. Keep the default house-building goal or enter your own, then click **Start**. The map shows each action as it happens. In **Activity**, select a tool call to inspect its arguments, or switch to **Messages** to read what the character says.

Use **Interrupt Intent** to end the current intent and ask the agent to replan from the current world. Use **Stop** to end the run. Changes already made stay in place, and starting again uses the current map and inventory. Reopening the app starts a fresh world.

The macOS ZIP uses an ad hoc signature and has no Apple notarization. You can also build the app locally.

## Build from source

Use a Swift 6 toolchain on macOS. The app has no third-party dependencies.

```sh
./Scripts/build-app.sh
```

Open `dist/GridWorld.app`. See the [reference](docs/reference.md) for API settings, Developer Tools, the tool protocol, debug exports, and test commands.

## License

[MIT](LICENSE)
