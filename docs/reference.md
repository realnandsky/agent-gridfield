# Agent Gridfield reference

## Model settings

Open **Settings** with the toolbar gear or ⌘,. Enter the complete Chat Completions endpoint or a supported base URL and set the model name. The endpoint must support function tools and `tool_choice: auto`. The app sends any returned `reasoning_content` back with the corresponding tool result. Remote endpoints use HTTPS. Loopback endpoints also accept HTTP and an empty key. The app stores each key in macOS Keychain under its API endpoint.

**Switch Configuration** lists saved configurations and presets for OpenAI, Zhipu AI, and DeepSeek. Select a saved configuration to use it on the next run. Selecting a preset fills in its address, model, and recommended options. Click **Save** to keep any changes. Models on the same endpoint can keep separate reasoning, streaming, and vision settings while sharing the key.

**Planning Effort** sets the Slow Brain's reasoning level and offers Provider Default, Off, Low, High, and Maximum, subject to provider and model support. Both brains share the model and API address. The Fast Brain uses `none` where supported, `minimal` for first-generation GPT-5 models, or `low` on the GLM Flash presets that require thinking. **Stream Responses** is on by default and can be turned off for compatibility. Settings apply on the next run. During a streamed Fast Brain request, the main window shows the request phase. The debugger's **Response** view shows the incoming content. The app executes only complete tool calls.

On upgrade, older configurations with reasoning set to **Off** start with **Low** for planning. To turn off the planner's reasoning on a supported model, choose **Off** in **Planning Effort** and save.

Requests time out after 90 seconds without new data. A single streamed request can run for up to 30 minutes. The total limit for a nonstreamed request is 3 minutes.

**Vision** defaults to on for the GPT-5 mini and GLM-5.3-Flash presets. For a different model, enable it if the model supports image input and function tools. Changes take effect on the next run.

The Zhipu AI preset uses a standard API key. The GLM-5.3-Flash preset offers Low, High, and Maximum for reasoning and requests streamed tool arguments when streaming is enabled.

## Developer Tools

Click **Developer Tools** (`{}`) in the toolbar. The **Brain Timeline** at the top plots the current or latest run across three shared-time lanes: **Fast** (blue API turns), **Slow** (purple background planning requests with a pulsing edge while active), and **Engine** (green physical intent execution and dashed gray `wait_for_plan` intervals). Vertical dashed connectors mark Slow-to-Fast handoffs (`plan_ready`, `plan_failed`, or `cancelled`). Selecting any request or engine segment selects the matching exchange below.

Under **API Requests**, filter by **All**, **Fast**, or **Slow**. Each row shows a Fast/Slow badge, semantic summary, optional eye icon, and duration. Select an API request to inspect its **Request** and **Response** bodies, HTTP headers, and status code. JSON is formatted by default. Turn on **Raw** to see the unformatted body. The debugger hides authentication headers and cookies and redacts the configured API key in payloads. Open **Plan** to inspect the current or selected background planning request, including its status (`Planning`, `Ready`, `Applied`, `Failed`, or `Cancelled`), `planID`, `createdTick`, elapsed time, `placementCount`, `bounds`, and summary. API request history lasts for the current session and can be cleared.

Use **Additional Instructions** to steer the agent. Click **Apply** to set the guidance or apply an empty field to clear it. During a run, applying guidance cancels the current request, intent, and background plan, then immediately wakes the Fast Brain with `player_input`. Steps already applied stay in the world. Between runs, the guidance applies the next time you click **Start**.

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

- `state.json` records the latest applied state, including the task goal, additional instructions, model settings, both map layers, avatar, inventory, notebook, character messages, vision call count, errors, and intent progress. `worldTick` counts ticks since the world was created or reset. While waiting for a model response or a local plan, the snapshot samples the clock about once per second. The phase `executing_intent` indicates an active intent. Loose and attached items have separate counts. Each update replaces the file as a whole.
- `events.jsonl` records each event with a time and sequence number. `api_request.brain` is `fast` or `slow`. Use `exchangeID` to connect API requests, streaming updates, responses, failures, and the intents they produce. `intent_started` and `intent_ended` mark the execution boundaries. Use the tool call ID and zero-based action index to follow progress through physical steps and action outcomes. The final streaming update contains the assembled response.
- `walk_step` records each cell traversed, with the action index, one-based step number, and avatar coordinates. `plan_step` records the other physical steps of `build_blueprint`, `apply_plan`, and `acquire`, with their one-based step numbers and an `action` containing the action description and outcome. `action_processed` records the outcome for the original action.
- `planner_started`, `planner_completed`, and `planner_cancelled` record the background proposal's lifecycle. Use `planID` to match these events with the slow `api_request`. `planner_started.sourceExchangeID` points to the fast request that returned `request_plan`. `model_woken` records the tick and reason for a new Fast Brain decision, including `start`, `tool_results`, `intent_failed`, `intent_interrupted`, `player_input`, `plan_ready`, or `plan_failed`.
- `tool_processed` records receipts for individual tools. `vision_called` records the vision ID and frame dimensions, along with the tool call ID and source exchange for agent-requested maps. The initial scan has `openingScan: true`. The subsequent `api_request` uses `visionID` for the first frame it carries and `additionalVisionIDs` for any further frames.

API records use the same key and header redaction as the debugger. Clearing API history during a trace adds a journal event. Trace files may still contain goals, prompts, and model output. They are intended for local debugging.

## The world and its tools

The map is 17 columns by 12 rows. The character moves one cell at a time in four directions. Grass, bushes, wood floors, and grass beds are walkable. Water, trees, walls, and corners block movement. **Reset World**, above the map, stops the current run and starts a fresh map with newly distributed bushes. It resets the character, inventory, notebook, and in-app activity, vision, and API history. Exported trace files remain available.

- `collect` takes an item or block from a neighboring cell. With `target: item`, it collects the named item, starting with loose items before attached ones. With `target: above`, it harvests grass, removes a bed or wall, or fells a tree that drops two logs in its cell. With `target: ground`, it removes a floor, returns one plank, and restores grass. Dots on tree canopies show the remaining branches.
- `craft` uses inventory items. One log makes four planks. Two grass and two planks make one grass bed.
- `place` builds on a cleared neighboring grass tile. Planks become floors or walls. A `wall` joins orthogonally adjacent walls, forming corners where they meet. Grass beds can sit on grass or floors.

During a run, the world clock advances eight times per second, including while a model request is pending. The agent submits an ordered list of actions with `act`. The local engine treats that list as an intent and advances it one step at a time against the live world. A walking step takes one tick regardless of model response time. The avatar waits when there is no intent to execute.

A failed action skips the rest of the intent. The receipt includes the attempted outcomes, skipped count, and current observation. When the current tool calls resolve, their receipts trigger the next model request. **Interrupt Intent** is available while an intent or background plan is running or a proposal is ready. It cancels that work, clears any ready proposal, skips the remaining calls in the interrupted response, and wakes the Fast Brain from the current world. **Stop** ends the run and cancels the active intent and pending model requests. Steps already applied stay in the world in either case.

### Background blueprint planning

The Fast Brain handles the live world and is the only brain that can call `act`. For a complex layout, it can call `request_plan` with a `brief` and optional `include_vision`, which defaults to `false`. The brief describes design intent and style. The Slow Brain chooses the site and coordinates using the goal, player instructions, and observation. The tool immediately returns `plan_requested`. The Fast Brain uses `wait_for_plan` while the plan is pending unless another action has a clear benefit. The engine gathers and crafts construction materials when executing the blueprint. The Slow Brain gets a snapshot of the world and returns a `summary` and a blueprint `placements` array in the background. With vision enabled, `include_vision: true` also gives the Slow Brain a map of that snapshot.

The engine keeps one proposal slot for the run. A new request replaces an older proposal or cancels the request that would have produced it. In the main window's sidebar, live **Fast** and **Slow** status capsules show each brain's state (`Idle`, `Thinking`, `Executing`, `Waiting for plan`, `Planning` with an elapsed timer and latest streaming preview line, or `Plan Ready` with tile count). When a proposal becomes ready or while `apply_plan` / `build_blueprint` executes, the live map overlays a translucent ghost blueprint for tiles not yet placed; each completed tile naturally replaces its ghost, while model vision snapshots (`visionFrame`) omit the ghost overlay and always depict only the actual world state. The Fast Brain can keep acting or use `{"action":"wait_for_plan"}` in `act` to wait until the proposal resolves. **Stop**, **Interrupt Intent**, and **Reset World** cancel active planning, clear the proposal slot, and remove the ghost blueprint.

The next Fast Brain decision receives `plan_ready` or `plan_failed` when the planner finishes. If an intent is still being applied, the app sends the planner result in the next decision's context alongside the intent receipt. A ready `pendingPlan` includes `planID`, `createdTick`, `summary`, `placementCount`, and `bounds`. To execute it, the Fast Brain calls `act` with `{"actions":[{"action":"apply_plan","planID":"<planID>"}]}`. The engine consumes the proposal when the action starts and runs the same blueprint planner used by `build_blueprint` against the current world. An unknown or already consumed ID returns `plan_unavailable`. A successful build returns the proposal's metadata as `appliedPlan` for verification.

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

`build_blueprint`, `apply_plan`, and `acquire` advance through steps on the map, including walking, felling trees, picking up items, crafting, and placing blocks. They report one result per action, `built` or `acquired` on success. The `plans` array gives the zero-based action `index`, number of physical `steps`, and an optional `failure` with a `reason`. Failure details can include a `[x,y]` `position`, `item`, and `needed` and `available` quantities. When a plan is infeasible at the start, the action leaves the world unchanged. If the player stops mid-action, the steps already applied stay in the world.

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

`collect_at` and `place_at` take integer `x` and `y` and walk to the nearest reachable neighboring tile to perform their action. `collect_at` shares the targeting and quantity fields of `collect`. `place_at` takes a `structure` and can take an exact `stand` as `[x,y]`. The stand must be a reachable tile orthogonally adjacent to the placement target. A coordinate action that fails its initial checks leaves the avatar in place.

For `craft` and item collection, `count` is an optional positive integer that defaults to 1. In `craft`, it counts recipe runs. For example, `{"action":"craft","item":"plank","count":3}` uses three logs and produces twelve planks. In `collect` and `collect_at`, it applies to `target: "item"` and counts items collected from the same tile, with loose items taken first. Collection with `target: "above"` or `target: "ground"` acts on one block. If the requested quantity is unavailable, the whole action fails.

### Model requests

The system prompt describes the tool parameters, world rules, and 8 Hz clock. The goal appears in the user message each turn. The Fast Brain can call `act`, `request_plan`, `memory`, and optional `vision` multiple times in one response. The app executes calls in the returned order, and the next model request pairs each call with its own receipt. A `finish` action ends the run and skips any later calls. The character speaks in **Messages** through the `say` action. Plain Chat Completions text appears in the API debugger. If a model returns only text with finish reason `stop`, the app retries up to twice with the text observation, the unsent draft, and instructions to call a tool. When the goal is complete, the Fast Brain should call `act` with `say` and then `finish` in one batch. A third text-only response ends the run with a protocol error.

The live context includes `worldTick`, `wakeReason`, and `planInProgress`. It appears in the opening user message or the last tool receipt of a follow-up. It includes `pendingPlan` when a proposal is ready. After a planning request fails, `planFailure` carries the error until the engine receives another planning request or clears the plan slot. After three consecutive intent failures, `planningSuggested: true` prompts the Fast Brain to request a blueprint.

An API observation includes `ground` and `above`, two 17 × 12 grids whose array indices are row coordinates. A row is a space-separated series of `x=ID` or `first..last=ID` values using the shared `legend`. Ranges are inclusive and each row covers every column, including grass and air. An example is `0=gr 1..7=wa 8..16=gr`. The encoding is `x_ranges_v1`.

Floors occupy the ground layer. Trees, bushes, walls, and beds occupy the upper layer. An empty upper cell is `air`. `items` totals loose items and tree branches by cell and type. The observation also contains the avatar's location, inventory, and notebook. Coordinates start at `[0,0]` in the upper-left corner and increase to the east and south.

## Tests

Run `./Scripts/test.sh`. It detects standalone Command Line Tools and adds the Swift Testing plugin path automatically, or runs `swift test` directly with a full Xcode toolchain:

```sh
swift test --disable-xctest -Xswiftc -plugin-path \
  -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
```

Tests cover the map, inventory, compact observations, tool calls and feedback, character messages, vision frames, world ticks, and interruption of requests and intents.
