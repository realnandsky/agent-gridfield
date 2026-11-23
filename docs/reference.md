# Agent Gridfield reference

## Model settings

Open **Settings** with the toolbar gear or ⌘,. Enter the complete Chat Completions endpoint or a supported base URL and set the model name. The endpoint must support function tools and `tool_choice: auto`. The app sends any returned `reasoning_content` back with the corresponding tool result. Remote endpoints use HTTPS. Loopback endpoints also accept HTTP and an empty key. The app stores each key in macOS Keychain under its API endpoint.

**Switch Configuration** lists saved configurations and presets for OpenAI, Zhipu AI, and DeepSeek. Select a saved configuration to use it on the next run. Selecting a preset fills in its address, model, and recommended options. Click **Save** to keep any changes. Models on the same endpoint can keep separate reasoning, streaming, and vision settings while sharing the key.

**Reasoning Effort** offers Provider Default, Off, Low, High, and Maximum, subject to provider and model support. **Stream Responses** is on by default and can be turned off for compatibility. Both settings apply on the next run. During a streamed request, the main window shows the request phase and the debugger's **Response** view shows the incoming content. The app executes only complete tool calls.

Requests time out after 90 seconds without new data. A single streamed request can run for up to 30 minutes. The total limit for a nonstreamed request is 3 minutes.

**Vision** defaults to on for the GPT-5 mini and GLM-5.3-Flash presets. For a different model, enable it if the model supports image input and function tools. Changes take effect on the next run.

The Zhipu AI preset uses a standard API key. The GLM-5.3-Flash preset offers Low, High, and Maximum for reasoning and requests streamed tool arguments when streaming is enabled.

## Developer Tools

Click **Developer Tools** (`{}`) in the toolbar. Select an API request to inspect its request and response bodies, HTTP headers, and status code. JSON is formatted by default. Turn on **Raw** to see the unformatted body. The debugger hides authentication headers and cookies and redacts the configured API key in payloads. API request history lasts for the current session and can be cleared.

Use **Additional Instructions** to send extra guidance with the next request. Click **Apply** to set it or apply an empty field to clear it.

Open **Notebook** to read the agent's current notes and named entries. Requests and tool receipts show the values present at the time. The `memory` tool replaces the notebook when given `text`. Empty text clears it. The notebook can hold up to 2,400 UTF-8 bytes and travels with each observation. It persists when a run is stopped and started in the same world and clears when the world is reset or the app reopens.

The same tool can update named entries, for example `{"set":{"idea":"Build a path by the lake"},"remove":["old-plan"]}`. IDs and text share a separate 2,400-byte limit. All changes in one call apply together. Invalid or oversized updates leave the prior values in place. `memory.entries` is included with tool receipts and appears in **Notebook**. A new run in the same world sees saved entries in its first tool receipt.

`recentHistory` covers up to four previous batches of processed actions, with a combined limit of 2,400 JSON bytes. Identical adjacent actions are grouped with a `count` of repeated actions. Blueprint history includes `placementCount` and `bounds`, the inclusive minimum and maximum `[x,y]` coordinates across the blueprint.

### Vision History

When vision is enabled, the first model request includes a 17 × 12 opening map labeled with coordinates. The agent can call `vision({})` during play to request a fresh map with its tool receipt. Each image and its accompanying text observation describe the same world state. Each image is sent once.

Open **Vision History** in Developer Tools to see opening scans, maps requested by the agent, and their delivery status. API requests with a map have an eye indicator. In the **Request** view, **View Sent Map** opens the matching image. The logged body lists the image dimensions and size in bytes.

### Live debug exports

The app writes a live trace by default to a private directory for each run under `~/Library/Caches/io.gridworld.macos/DebugTrace/`. Directory names include the model, reasoning effort, local start time, and process ID, for example `glm-5.3-flash_max_2026-11-19_21-49-09-000_p23855`. The event journal rotates at about 16 MiB, preserving the latest segment and `events.previous.jsonl`. At launch, the cache keeps traces from running app processes and the three most recent traces from closed ones.

Pass `--no-debug-export` to disable disk exports. To capture an isolated run, launch a separate instance with `--debug-dir` and a new absolute path.

```sh
trace_root="$(mktemp -d)"
open -n "$PWD/dist/GridWorld.app" --args --debug-dir "$trace_root/session"
```

After the app opens, read `"$trace_root/session/state.json"` or follow `"$trace_root/session/events.jsonl"`.

- `state.json` records the latest applied state, including the task goal, additional instructions, model settings, both map layers, avatar, inventory, notebook, character messages, vision call count, errors, and batch progress. Loose and attached items have separate counts. Each update replaces the file as a whole.
- `events.jsonl` records each event with a time and sequence number. Use `exchangeID` to connect requests, streaming updates, responses or failures, and projected batch receipts. Use the tool call ID and zero-based action index to find outcomes actually applied to the world. An interrupted batch retains both its projected receipt and its actual progress. The final streaming update contains the assembled response.
- `walk_step` records each cell traversed, with the action index, one-based step number, and avatar coordinates. `plan_step` records the other physical steps of `build_blueprint` and `acquire`, with their one-based step numbers and an `action` containing the action description and outcome. `action_processed` records the outcome for the original action.
- `tool_processed` records receipts for individual tools. `vision_called` records the vision ID and frame dimensions, along with the tool call ID and source exchange for agent-requested maps. The initial scan has `openingScan: true`. The subsequent `api_request` uses `visionID` for the first frame it carries and `additionalVisionIDs` for any further frames.

API records use the same key and header redaction as the debugger. Clearing API history during a trace adds a journal event. Trace files may still contain goals, prompts, and model output. They are intended for local debugging.

## The world and its tools

The map is 17 columns by 12 rows. The character moves one cell at a time in four directions. Grass, bushes, wood floors, and grass beds are walkable. Water, trees, walls, and corners block movement. **Reset World**, above the map, stops the current run and starts a fresh map with newly distributed bushes. It resets the character, inventory, notebook, and in-app activity, vision, and API history. Exported trace files remain available.

- `collect` takes an item or block from a neighboring cell. With `target: item`, it collects the named item, starting with loose items before attached ones. With `target: above`, it harvests grass, removes a bed or wall, or fells a tree that drops two logs in its cell. With `target: ground`, it removes a floor, returns one plank, and restores grass. Dots on tree canopies show the remaining branches.
- `craft` uses inventory items. One log makes four planks. Two grass and two planks make one grass bed.
- `place` builds on a cleared neighboring grass tile. Planks become floors or walls. A `wall` joins orthogonally adjacent walls, forming corners where they meet. Grass beds can sit on grass or floors.

The agent submits ordered action batches with `act`. The app validates a batch and projects its outcome, then plays each action on the map. Playback intervals range from 180 to 400 ms based on the time spent generating the batch and the number of steps. The model can plan the next batch during playback. A failed action skips the rest of the batch. The receipt includes the attempted outcomes, skipped count, and final observation. **Stop** cancels pending requests and any remaining playback. Completed actions stay applied.

### Blueprints and inventory targets

`build_blueprint` takes a nonempty `placements` array of `{x,y,structure}` objects. Each object describes a tile in the finished layout. `wall` picks its connections from adjacent wall tiles. The other blueprint structures are `floor` and `grass_bed`. A floor and a grass bed can share a tile. An existing matching structure counts toward the completed layout. Water and conflicting structures block a placement.

The engine clears trees and bushes on the footprint, opens paths through trees when needed, and gathers and crafts the required materials. It chooses construction order and reachable stands so the avatar can build without trapping itself. This blueprint creates a wall corner beside a floor tile.

```json
{
  "actions": [
    {"action": "build_blueprint", "placements": [
      {"x": 9, "y": 5, "structure": "wall"},
      {"x": 9, "y": 6, "structure": "wall"},
      {"x": 10, "y": 6, "structure": "wall"},
      {"x": 10, "y": 5, "structure": "floor"}
    ]}
  ]
}
```

`acquire` takes an `item` and a positive integer `count` for the desired inventory total. For example, `{"action":"acquire","item":"grass_bed","count":2}` asks the engine to bring the number of carried grass beds to two. The engine uses existing inventory, finds reachable resources, and runs recipes as needed. A recipe's batch yield can leave extra items.

Both actions play actual steps on the map, including walking, felling trees, picking up items, crafting, and placing blocks. They report one result per action, `built` or `acquired` on success. The `plans` array gives the zero-based action `index`, number of physical `steps`, and an optional `failure` with a `reason`. Failure details can include a `[x,y]` `position`, `item`, and `needed` and `available` quantities. An infeasible plan leaves the world as it was before that action. If the player stops during playback, steps already applied stay in the world.

### Direct actions

`walk_to` takes integer `x` and `y` and follows the shortest route one cell at a time. This batch walks from the start to `(10, 5)` and fells the tree to the east.

```json
{
  "actions": [
    {"action": "walk_to", "x": 10, "y": 5},
    {"action": "collect", "direction": "east", "target": "above"}
  ]
}
```

A successful walk yields one `arrived` outcome in `results`. The `walks` array lists its action index, destination, and number of steps. The step count is zero when the agent is already there. A blocked route returns `unreachable`. An out-of-bounds destination returns `boundary`.

`collect_at` and `place_at` take integer `x` and `y` and walk to the nearest reachable neighboring tile to perform their action. `collect_at` shares the targeting and quantity fields of `collect`. `place_at` takes a `structure` and can take an exact `stand` as `[x,y]`. The stand must be a reachable tile orthogonally adjacent to the placement target. A failed coordinate action leaves the avatar in place.

For `craft` and item collection, `count` is an optional positive integer that defaults to 1. In `craft`, it counts recipe runs. For example, `{"action":"craft","item":"plank","count":3}` uses three logs and produces twelve planks. In `collect` and `collect_at`, it applies to `target: "item"` and counts items collected from the same tile, with loose items taken first. Collection with `target: "above"` or `target: "ground"` acts on one block. If the requested quantity is unavailable, the whole action fails.

### Model requests

The system prompt describes the tool parameters and world rules. The goal appears in the user message each turn. The agent can call `act`, `memory`, and optional `vision` multiple times in one response. The app executes calls in the returned order, and the next model request pairs each call with its own receipt. A `finish` action ends the run and skips any later calls. The character speaks in **Messages** through the `say` action. Plain Chat Completions text appears in the API debugger. If a model returns only text with finish reason `stop`, the app retries once with a protocol reminder and a text observation.

An API observation includes `ground` and `above`, two 17 × 12 grids whose array indices are row coordinates. A row is a space-separated series of `x=ID` or `first..last=ID` values using the shared `legend`. Ranges are inclusive and each row covers every column, including grass and air. An example is `0=gr 1..7=wa 8..16=gr`. The encoding is `x_ranges_v1`. The debug state uses `schemaVersion` 3.

Floors occupy the ground layer. Trees, bushes, walls, and beds occupy the upper layer. An empty upper cell is `air`. `items` totals loose items and tree branches by cell and type. The observation also contains the avatar's location, inventory, and notebook. Coordinates start at `[0,0]` in the upper-left corner and increase to the east and south.

## Tests

Run `./Scripts/test.sh`. It detects standalone Command Line Tools and adds the Swift Testing plugin path automatically, or runs `swift test` directly with a full Xcode toolchain:

```sh
swift test --disable-xctest -Xswiftc -plugin-path \
  -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
```

Tests cover the map, inventory, compact observations, tool calls and feedback, character messages, vision frames, and interruption of requests and action batches.
