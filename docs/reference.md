# Agent Gridfield reference

## Model settings

Open **Settings** with the toolbar gear or ⌘,. Enter the complete Chat Completions endpoint or a supported base URL and set the model name. The endpoint must support function tools and `tool_choice: auto`. The app sends any returned `reasoning_content` back with the corresponding tool result. Remote endpoints use HTTPS. Loopback endpoints also accept HTTP and an empty key. The app stores each key in macOS Keychain under its API endpoint.

**Switch Configuration** lists saved configurations and presets for OpenAI, Zhipu AI, and DeepSeek. Select a saved configuration to use it on the next run. Selecting a preset fills in its address, model, and recommended options. Click **Save** to keep any changes. Models on the same endpoint can keep separate reasoning, streaming, and vision settings while sharing the key.

**Reasoning Effort** offers Provider Default, Off, Low, High, and Maximum, subject to provider and model support. **Stream Responses** is on by default and can be turned off for compatibility. Both settings apply on the next run. During a streamed request, the main window shows the request phase and the debugger's **Response** view shows the incoming content. The app executes only complete tool calls.

**Vision** defaults to on for the GPT-5 mini and GLM-5.3-Flash presets. For a different model, enable it if the model supports image input and function tools. Changes take effect on the next run.

The Zhipu AI preset uses a standard API key. The GLM-5.3-Flash preset offers Low, High, and Maximum for reasoning and requests streamed tool arguments when streaming is enabled.

## Developer Tools

Click **Developer Tools** (`{}`) in the toolbar. Select an API request to inspect its request and response bodies, HTTP headers, and status code. JSON is formatted by default. Turn on **Raw** to see the unformatted body. The debugger hides authentication headers and cookies and redacts the configured API key in payloads. API request history lasts for the current session and can be cleared.

Use **Additional Instructions** to send extra guidance with the next request. Click **Apply** to set it or apply an empty field to clear it.

Open **Notebook** to read the agent's current notes and named entries. Requests and tool receipts show the values present at the time. The `memory` tool replaces the notebook when given `text`. Empty text clears it. The notebook can hold up to 2,400 UTF-8 bytes and travels with each observation. It persists when a run is stopped and started in the same world and resets when the app reopens.

The same tool can update named entries, for example `{"set":{"idea":"Build a path by the lake"},"remove":["old-plan"]}`. IDs and text share a separate 2,400-byte limit. All changes in one call apply together. Invalid or oversized updates leave the prior values in place. `memory.entries` is included with tool receipts and appears in **Notebook**. A new run in the same world sees saved entries in its first tool receipt.

`recentHistory` covers up to four previous batches of processed actions and queries, with a combined limit of 2,400 JSON bytes. Identical adjacent actions are counted together. Older query results keep at most three resource candidates, sites, or wall seams. The current query receipt contains the full results. Query indices in history refer to their original batches.

### Vision History

An agent with vision enabled can call `vision({})` to request a 17 × 12 map labeled with coordinates. The image and its accompanying text observation describe the same world state. The app sends each rendered image with the immediately following API request.

Open **Vision History** in Developer Tools to see every call in the session, its map, and its delivery status. API requests with a map have an eye indicator. In the **Request** view, **View Sent Map** opens the matching image. The logged body lists the image dimensions and size in bytes.

### Live debug exports

Since version 1.8.1, the app writes a live trace by default to a private session directory under `~/Library/Caches/io.gridworld.macos/DebugTrace/`. The directory name and `state.json` include the process ID. Match the process ID, timestamp, and goal to the session you want to inspect. The event journal rotates at about 16 MiB, preserving the latest segment and `events.previous.jsonl`. At startup, the cache keeps open sessions and the three most recent closed ones.

Pass `--no-debug-export` to disable disk exports. To capture an isolated run, launch a separate instance with `--debug-dir` and a new absolute path.

```sh
trace_root="$(mktemp -d)"
open -n "$PWD/dist/GridWorld.app" --args --debug-dir "$trace_root/session"
```

After the app opens, read `"$trace_root/session/state.json"` or follow `"$trace_root/session/events.jsonl"`.

- `state.json` records the latest applied state, including the task goal, additional instructions, model settings, both map layers, avatar, inventory, notebook, character messages, vision call count, errors, and batch progress. Loose and attached items have separate counts. Each update replaces the file as a whole.
- `events.jsonl` records each event with a time and sequence number. Use `exchangeID` to connect requests, streaming updates, responses or failures, and projected batch receipts. Use the tool call ID and zero-based action index to find outcomes actually applied to the world. An interrupted batch retains both its projected receipt and its actual progress. The final streaming update contains the assembled response.
- `walk_step` records each cell traversed by `walk_to`, with the action index, one-based step number, and avatar coordinates. `action_processed` records the arrival.
- `tool_processed` records receipts for individual tools. `vision_called` records the vision ID, tool call ID, source exchange, and frame dimensions. The subsequent `api_request` uses `visionID` to identify the frame it carries.

API records use the same key and header redaction as the debugger. Clearing API history adds a journal event. Trace files may still contain goals, prompts, and model output. They are intended for local debugging.

## The world and its tools

The map is 17 columns by 12 rows. The character moves one cell at a time in four directions. Grass, bushes, wood floors, and grass beds are walkable. Water, trees, walls, and corners block movement. Reopening the app resets the map and redistributes the bushes.

- `collect` takes an item or block from a neighboring cell. With `target: item`, it collects a single named item, starting with loose items before attached ones. With `target: above`, it harvests grass, removes a bed or wall, or fells a tree that drops two logs in its cell. With `target: ground`, it removes a floor, returns one plank, and restores grass. Dots on tree canopies show the remaining branches.
- `craft` uses inventory items. One log makes four planks. Two grass and two planks make one grass bed.
- `place` builds on a cleared neighboring grass tile. Planks become floors, straight walls, or corners. Straight walls have north–south and east–west variants. Corners have four orientations. Grass beds can sit on grass or floors.

The agent submits ordered action batches with `act`. The app validates a batch and projects its outcome, then plays each action on the map. Playback intervals range from 180 to 400 ms based on the time spent generating the batch and the number of steps. The model can plan the next batch during playback. A failed action skips the rest of the batch. The receipt includes the attempted outcomes, skipped count, and final observation. **Stop** cancels pending requests and any remaining playback. Completed actions stay applied.

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

The read-only `query` tool accepts one or more entries in `queries`. Each entry uses the `query` field to specify an operation. The corresponding receipt uses the entry's zero-based `index`.

| Operation | Parameters and behavior |
| --- | --- |
| `collect_at` (action) | Takes integer `x` and `y` and the same `target` and `item` fields as `collect`. Walks to the nearest reachable neighboring tile and collects once. |
| `place_at` (action) | Takes integer `x` and `y` and a `structure`. Walks to the nearest reachable neighboring tile and places once. |
| `find_resources` (query) | Takes `resource` such as `tree`, `bush`, or an item name. Ranks candidates by walking distance to a collection tile. The count for a tree is how many logs it drops. |
| `estimate_materials` (query) | Takes `counts`, a map of structure names to quantities such as `{"wall_ns":7,"floor":1,"grass_bed":1}`. Returns required items, craft counts, and raw materials still needed after inventory. |
| `preview_build` (query) | Takes `placements`, an ordered array of `{x,y,structure}`. Returns the material estimate and the first placement that fails or is unreachable. It simulates placement with virtual materials. On success, `wallSeams` lists adjacent walls where only one arm points across their shared edge. |
| `find_build_sites` (query) | Takes integer `width` and `height`. Reports rectangular sites away from water and existing structures, along with entrances, walking distance, and tiles to clear. |

Resource and site queries accept `limit` from 1 to 10, with a default of 3. You can inspect all calls and receipts in Developer Tools.

The system prompt describes the tool parameters and world rules. The goal appears in the user message each turn. The agent selects exactly one available tool from `act`, `memory`, `query`, and optional `vision`. The character speaks in **Activity** through the `say` action and ends a run with `finish`. Plain Chat Completions text appears in the API debugger. If a model returns only text with finish reason `stop`, the app retries once with a protocol reminder and a text observation.

An API observation includes `ground` and `above`, two 17 × 12 grids whose array indices are row coordinates. A row is a space-separated series of `x=ID` or `first..last=ID` values using the shared `legend`. Ranges are inclusive and each row covers every column, including grass and air. An example is `0=gr 1..7=wa 8..16=gr`. The encoding is `x_ranges_v1`. The debug state uses `schemaVersion` 3.

Floors occupy the ground layer. Trees, bushes, walls, and beds occupy the upper layer. An empty upper cell is `air`. `items` totals loose items and tree branches by cell and type. The observation also contains the avatar's location, inventory, and notebook. Coordinates start at `[0,0]` in the upper-left corner and increase to the east and south.

## Tests

Run `swift test` with a full Xcode toolchain. With standalone Command Line Tools 27, point Swift at the Swift Testing plugin.

```sh
swift test --disable-xctest -Xswiftc -plugin-path \
  -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
```

Tests cover the map, inventory, compact observations, tool calls and feedback, character messages, vision frames, and interruption of requests and action batches.
