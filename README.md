<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://github.com/user-attachments/assets/fe853809-ba8b-400b-83ab-a9a0da25be8a" alt="Logo" width="128">
  <br>Gizmo
</h1>
  <p align="center">
    A moldable Linux terminal, based on Ghostty.
    <br />
    A native GUI or embeddable library via <code>libghostty</code>.
    <br />
    <a href="#about">About</a>
    ·
    <a href="https://ghostty.org/download">Download</a>
    ·
    <a href="https://ghostty.org/docs">Documentation</a>
    ·
    <a href="CONTRIBUTING.md">Contributing</a>
    ·
    <a href="HACKING.md">Developing</a>
  </p>
</p>

## About

Gizmo is a Linux fork of [Ghostty](https://github.com/ghostty-org/ghostty).
It adds authenticated local agent control, custom native panels, tool workflows,
and switchable horizontal or vertical tabs.

The application executable is `gizmo`. It retains Ghostty's default application
identity and configuration paths. The shared terminal engine and upstream platform code remain intact.

**`libghostty`** is a cross-platform, zero-dependency C and Zig library
for building terminal emulators or utilizing terminal functionality
(such as style parsing). Anyone can use `libghostty` to build a terminal
emulator or embed a terminal into their own applications. See
[Ghostling](https://github.com/ghostty-org/ghostling) for a minimal complete project
example or the [`examples` directory](https://github.com/ghostty-org/ghostty/tree/main/example)
for smaller examples of using `libghostty` in C and Zig.

For more details, see [About Ghostty](https://ghostty.org/docs/about).

## Gizmo: unified CLI

Build the Linux application with `zig build -Doptimize=ReleaseFast`.
See [HACKING.md](HACKING.md) for dependencies.
The executable is `zig-out/bin/gizmo`.
The examples below assume its directory is on `PATH`.

One executable launches the application, runs utilities, manages saved data,
and controls running instances:

```sh
gizmo
gizmo list-fonts
gizmo start -- --class=org.gizmo.Terminal
gizmo instances
gizmo inspect --instance=ID
gizmo stop --instance=ID
gizmo restart --instance=ID
```

`gizmo` launches normally. `start` launches an independent controlled instance
and enables agent access for that process only.
Arguments after `start --` are application launch arguments, including `-e` commands.
The start command returns after the authenticated endpoint becomes available.

Stop uses normal application close confirmation.
Restart waits for the selected process to exit before starting its replacement.
It preserves launch arguments and working directory, not terminal sessions.
If closing does not complete, restart must not create a replacement.

Use `instances` to find instance IDs.
If multiple instances exist, select one with `--instance=ID`.
Ambiguous commands do not silently choose an application.
Utility commands do not need a running window.
Existing `+list-fonts`-style utility syntax remains available.

### Saved configuration and live overrides

Configuration commands read and edit saved settings by default.
They do not need D-Bus or a running application:

```sh
gizmo config get font-size
gizmo config set font-size 16
gizmo config reset font-size
gizmo config validate
```

Saved edits preserve comments and unrelated settings.
Set replaces that key's assignments in the preferred file.
For repeatable keys, the supplied lines replace that file's entries in order.
Included files retain their normal precedence and can override these saved values.
Reset removes the key's assignments from the preferred user file; included files remain unchanged.
Saved writes do not silently change an already running instance.
The fork still uses Ghostty's configuration location by default.

Use `--live` for the selected instance's effective configuration or session overrides:

```sh
gizmo config get font-size --live --instance=ID
gizmo config set font-size 18 --live --instance=ID
gizmo config reload --instance=ID
```

Reload is inherently live. It reads saved configuration and original launch arguments.
Settings retain their normal runtime or new-terminal semantics.

### Agent control

Normal launches disable agent control by default.
Enable it persistently when trusted local agents need access:

```sh
gizmo agent enable
gizmo --class=org.gizmo.Terminal
```

The enable command preserves the user configuration text and records
`agent-control = true`. Restart an already running instance after enabling it.
Use a separate class when running this fork alongside installed Ghostty.
`agent disable` persists the disabled setting and revokes the selected endpoint.

Gizmo creates private credentials. The CLI discovers the running instance;
you do not need to copy tokens or know its D-Bus name:

```sh
gizmo inspect
gizmo tabs list
gizmo terminal read SURFACE
gizmo terminal send SURFACE --text-file=command.txt
gizmo terminal action SURFACE new_split:right
gizmo terminal status SURFACE
```

`inspect` returns stable window, tab, and surface IDs.
Unrealized terminal leaves expose `ready: false` and a widget ID.
Select their tab before sending terminal input.

### JSON and direct commands

`agent discover` describes methods, action parameters, physical keys, settings,
and application/window GTK actions.
The direct commands also accept `--params=JSON` and `--params-file=PATH`.
Use `-` to read a file argument from stdin.

For complete JSON requests:

```sh
gizmo agent request --request-file=request.json
gizmo agent request --request='{"method":"ui.tree"}'
```

`screen.read` returns terminal text/history, dimensions, and cursor position.
`screen.capture` returns a rendered window PNG.
`ui.tree` and `ui.action` inspect and operate native controls.
`input.text`, `input.key`, `input.mouse`, and `input.scroll` use existing terminal
input paths. Binding and GTK actions use the same handlers as normal UI actions.

Raw `config.get`, `config.set`, `config.reset`, and `config.reload` remain live API methods.
Raw changes remain session-local unless `persist_path` names an absolute file.
That explicit persistence replaces the file with the complete canonical configuration.

### Security and protocol

Treat agent access as shell access, not as a sandbox.
Enable it only for trusted local agents.
Generated credentials remain in application memory and private discovery files;
Gizmo does not add them to child-process environments.

Discovery uses `$XDG_RUNTIME_DIR/gizmo`, with directory mode `0700` and file
mode `0600`. The CLI checks ownership, file type, permissions, and the live
D-Bus peer PID. Instance listings do not expose credentials.

The transport remains session D-Bus, not TCP:

- Interface: `org.gizmo.Agent1`
- Object: `/org/gizmo/Agent1`
- Method: `Request(s JSON) -> (s JSON)`
- Request: `{"token":"secret","method":"tree","params":{}}`
- Success: `{"ok":true,"result":...}`
- Failure: D-Bus error `org.gizmo.Agent1.Error`

Control, saved-data, and lifecycle commands return JSON and a nonzero status on failure.
Requests are limited to 1 MiB; responses are limited to 16 MiB.
The explicit `GIZMO_AGENT_TOKEN`/`--class` path and `+agent-control` raw command
remain available for manually managed connections.
Explicit raw revocation uses `config.set` with `agent-control = false` and
`revoke_agent_control: true`.

Screen images cover Gizmo's rendered window content, not compositor decorations
or other applications. Unrendered windows return an explicit capture error.
Terminal text does not represent embedded images.

## Gizmo: reusable extensions

An extension defines named actions independently of its optional panel.
Actions can appear in the real command palette without creating a window.
Native buttons, palette entries, and authenticated API calls share one dispatcher.

`extensions discover` returns schemas and complete examples without starting Gizmo.
Saved definition commands work offline by default.
Use `--live` to inspect or change a running instance's loaded extensions.
Invoking actions, inspecting runtime context, and saving or loading runtime state are inherently live.

For an immediate interactive installation, save parameters in a JSON file, then run:

```sh
gizmo extensions install --live --params-file=extension.json
gizmo extensions invoke hello --action=run
```

For example, `extension.json` can contain:

```json
{
  "definition": {
    "id": "hello",
    "title": "Gizmo tools",
    "panel": true,
    "actions": [
      {
        "id": "run",
        "title": "Print greeting",
        "type": "workflow",
        "context": "none",
        "argv": ["/usr/bin/printf", "Hello %s\n", { "state": "name" }]
      }
    ],
    "elements": [
      { "id": "name", "type": "entry", "label": "Name", "text": "Gizmo" },
      { "id": "run-button", "type": "button", "label": "Run", "action": "run" }
    ]
  }
}
```

Omit the panel and elements for a headless capability.
Panels support labels, entries, buttons, toggles, and selections.
Agents can inspect state, update values, and apply JSON Merge Patch.
Installing, restoring, reading, and changing state never execute actions.

Terminal actions resolve caller, focused, or explicitly supplied runtime context.
Definitions cannot store surface IDs that become stale after restart.
For an explicit target, invoke with `context: {"surface": "ID from inspect"}`.
Existing actions such as `new_tab` and `new_split:right` create terminals.
`extensions.context` exposes resolved context and OSC status as inspection data.

Workflow arguments remain separate, without implicit shell interpolation.
Arguments can read an element, state value, or workspace/cwd/surface context.
Jobs run asynchronously with bounded output, deadlines, cancellation, and
inspectable stdout/stderr, exit status, and lossless base64 streams.
Cancellation kills the tool's process group.
Descendants that create another session or process group are not tracked.

### Persistence and workspaces

Install saved extensions without starting the application:

```sh
gizmo extensions install --params-file=extension.json
gizmo extensions list
gizmo extensions inspect hello
gizmo extensions export hello
```

Definitions and state live in
`$XDG_DATA_HOME/gizmo/extensions/catalog.json`, with the standard user-data fallback.
Writers lock the catalog across each update and replace it atomically.
Offline edits do not change a running instance's loaded definitions.

For live installations, use `persist: true` or call `extensions.save` explicitly.

App-scoped state is shared within the application.
Workspace-scoped state uses an explicit canonical directory.
Use `extensions.load` with a workspace to select its saved state.
A missing workspace slot starts from defaults, never another workspace's values.
Save/update cannot silently switch workspace keys.

Definitions restore inertly after agent access is enabled.
Workspace definitions require an explicit workspace load before use.
Persistent API state updates save automatically; native field edits require save.
Saved `extensions.export` returns installation-compatible data.
Use `--live` to export current runtime state instead.
Saved removal does not cancel running actions.
Live removal cancels jobs and also removes saved state when the extension is persistent.
Closing a panel only hides it; hidden panels do not keep the application alive.

## Gizmo: program status

Gizmo consumes the existing [Program Status Protocol, OSC 7501](https://www.superlogical.com/rex/docs/build/program-status).
Programs can report identity, idle/working/done/blocked/error state, progress,
messages, and named child records. Programs must emit reports themselves;
Gizmo does not infer agent identity from terminal text.

Each pane keeps bounded records. Prompt/process-exit events remove transient
working/blocked records; completed/error records survive. Full reset clears all.
Tab indicators aggregate every pane, including panes hidden by split zoom.
Summary priority is blocked, error, done, working, then idle.

Use `terminal status SURFACE`, `status.list`, or `status.get` to inspect records.
The same information is available to extension context inspection.
Reports are untrusted data. They never authorize commands or grant permission.

## Gizmo: tabs and collapsible sidebar

The default is vertical tabs with a compact rail.
Click the sidebar toggle to open an expanded overlay.
Expansion is not hover-driven and does not resize the terminal grid.
Hiding the rail releases its width to the terminal.

```ini
gtk-tabs-orientation = vertical
gtk-sidebar-state = compact
```

Sidebar states are `compact`, `expanded`, and `hidden`.
Horizontal tabs remain available and retain top/bottom placement.
Explicit `window-show-tab-bar = never` hides the vertical sidebar.

Rows use middle-truncated titles, status/attention indicators, and contextual
close controls. Right-click or Menu/Shift+F10 opens tab operations.
Middle-click closes; drag reorders or transfers tabs between windows.
Move to New Window remains available in the context menu.

After focusing the list, arrows/Home/End navigate, Enter returns to the terminal,
Escape collapses and returns focus, F2 renames, and Delete closes.
Close confirmation remains active when configured.

GTK actions expose `win.set-tabs-orientation`, `win.set-sidebar-state`,
`win.toggle-sidebar`, and `win.focus-tab-list`.
Stateful actions accept strings and are discoverable through `gtk.actions`.
Explicit configuration updates reset session overrides; soft theme changes preserve them.

These Gizmo features currently target Linux GTK only.

## Download

See the [download page](https://ghostty.org/download) on the Ghostty website.

## Documentation

See the [documentation](https://ghostty.org/docs) on the Ghostty website.

## Contributing and Developing

If you have any ideas, issues, etc. regarding Ghostty, or would like to
contribute to Ghostty through pull requests, please check out our
["Contributing to Ghostty"](CONTRIBUTING.md) document. Those who would like
to get involved with Ghostty's development as well should also read the
["Developing Ghostty"](HACKING.md) document for more technical details.

## Roadmap and Status

Ghostty is stable and in use by millions of people and machines daily.

The high-level ambitious plan for the project, in order:

|  #  | Step                                                    | Status |
| :-: | ------------------------------------------------------- | :----: |
|  1  | Standards-compliant terminal emulation                  |   ✅   |
|  2  | Competitive performance                                 |   ✅   |
|  3  | Rich windowing features -- multi-window, tabbing, panes |   ✅   |
|  4  | Native Platform Experiences                             |   ✅   |
|  5  | Cross-platform `libghostty` for Embeddable Terminals    |   ✅   |
|  6  | Ghostty-only Terminal Control Sequences                 |   ❌   |

Additional details for each step in the big roadmap below:

#### Standards-Compliant Terminal Emulation

Ghostty implements all of the regularly used control sequences and
can run every mainstream terminal program without issue. For legacy sequences,
we've done a [comprehensive xterm audit](https://github.com/ghostty-org/ghostty/issues/632)
comparing Ghostty's behavior to xterm and building a set of conformance
test cases.

In addition to legacy sequences (what you'd call real "terminal" emulation),
Ghostty also supports more modern sequences than almost any other terminal
emulator. These features include things like the Kitty graphics protocol,
Kitty image protocol, clipboard sequences, synchronized rendering,
light/dark mode notifications, and many, many more.

We believe Ghostty is one of the most compliant and feature-rich terminal
emulators available.

Terminal behavior is partially a de jure standard
(i.e. [ECMA-48](https://ecma-international.org/publications-and-standards/standards/ecma-48/))
but mostly a de facto standard as defined by popular terminal emulators
worldwide. Ghostty takes the approach that our behavior is defined by
(1) standards, if available, (2) xterm, if the feature exists, (3)
other popular terminals, in that order. This defines what the Ghostty project
views as a "standard."

#### Competitive Performance

Ghostty is generally in the same performance category as the other highest
performing terminal emulators.

"The same performance category" means that Ghostty is much faster than
traditional or "slow" terminals and is within an unnoticeable margin of the
well-known "fast" terminals. For example, Ghostty and Alacritty are usually within
a few percentage points of each other on various benchmarks, but are both
something like 100x faster than Terminal.app and iTerm. However, Ghostty
is much more feature rich than Alacritty and has a much more native app
experience.

This performance is achieved through high-level architectural decisions and
low-level optimizations. At a high-level, Ghostty has a multi-threaded
architecture with a dedicated read thread, write thread, and render thread
per terminal. Our renderer uses OpenGL on Linux and Metal on macOS.
Our read thread has a heavily optimized terminal parser that leverages
CPU-specific SIMD instructions. Etc.

#### Rich Windowing Features

The Mac and Linux (build with GTK) apps support multi-window, tabbing, and
splits with additional features such as tab renaming, coloring, etc. These
features allow for a higher degree of organization and customization than
single-window terminals.

#### Native Platform Experiences

Ghostty is a cross-platform terminal emulator but we don't aim for a
least-common-denominator experience. There is a large, shared core written
in Zig but we do a lot of platform-native things:

- The macOS app is a true SwiftUI-based application with all the things you
  would expect such as real windowing, menu bars, a settings GUI, etc.
- macOS uses a true Metal renderer with CoreText for font discovery.
- macOS supports AppleScript, Apple Shortcuts (AppIntents), etc.
- The Linux app is built with GTK.
- The Linux app integrates deeply with systemd if available for things
  like always-on, new windows in a single instance, cgroup isolation, etc.

Our goal with Ghostty is for users of whatever platform they run Ghostty
on to think that Ghostty was built for their platform first and maybe even
exclusively. We want Ghostty to feel like a native app on every platform,
for the best definition of "native" on each platform.

#### Cross-platform `libghostty` for Embeddable Terminals

In addition to being a standalone terminal emulator, Ghostty is a
C-compatible library for embedding a fast, feature-rich terminal emulator
in any 3rd party project. This library is called `libghostty`.

Due to the scope of this project, we're breaking libghostty down into
separate libraries, starting with `libghostty-vt`. The goal of
this project is to focus on parsing terminal sequences and maintaining
terminal state. This is covered in more detail in this
[blog post](https://mitchellh.com/writing/libghostty-is-coming).

`libghostty-vt` is already available and usable today for Zig and C and
is compatible for macOS, Linux, Windows, and WebAssembly. The functionality
is extremely stable (since its been proven in Ghostty GUI for a long time),
but the API signatures are still in flux.

`libghostty` is already heavily in use. See [`examples`](https://github.com/ghostty-org/ghostty/tree/main/example)
for small examples of using `libghostty` in C and Zig or the
[Ghostling](https://github.com/ghostty-org/ghostling) project for a
complete example. See [awesome-libghostty](https://github.com/Uzaaft/awesome-libghostty)
for a list of projects and resources related to `libghostty`.

`libghostty-vt` is released on its own, separately from Ghostty, with
`vt-X.Y.Z` tags. To build or package it, see
[`PACKAGING-LIBGHOSTTY.md`](PACKAGING-LIBGHOSTTY.md). To use it from a
CMake project, see [`dist/cmake/README.md`](dist/cmake/README.md). We're
still working on a better docs experience, but our
[Doxygen website](https://lib.ghostty.org/vt/) is a good resource
for the C API.

#### Ghostty-only Terminal Control Sequences

We want and believe that terminal applications can and should be able
to do so much more. We've worked hard to support a wide variety of modern
sequences created by other terminal emulators towards this end, but we also
want to fill the gaps by creating our own sequences.

We've been hesitant to do this up until now because we don't want to create
more fragmentation in the terminal ecosystem by creating sequences that only
work in Ghostty. But, we do want to balance that with the desire to push the
terminal forward with stagnant standards and the slow pace of change in the
terminal ecosystem.

We haven't done any of this yet.

## Crash Reports

Ghostty has a built-in crash reporter that will generate and save crash
reports to disk. The crash reports are saved to the `$XDG_STATE_HOME/ghostty/crash`
directory. If `$XDG_STATE_HOME` is not set, the default is `~/.local/state`.
**Crash reports are _not_ automatically sent anywhere off your machine.**

Crash reports are only generated the next time Ghostty is started after a
crash. If Ghostty crashes and you want to generate a crash report, you must
restart Ghostty at least once. You should see a message in the log that a
crash report was generated.

> [!NOTE]
>
> Use the `ghostty +crash-report` CLI command to get a list of available crash
> reports. A future version of Ghostty will make the contents of the crash
> reports more easily viewable through the CLI and GUI.

Crash reports end in the `.ghosttycrash` extension. The crash reports are in
[Sentry envelope format](https://develop.sentry.dev/sdk/envelopes/). You can
upload these to your own Sentry account to view their contents, but the format
is also publicly documented so any other available tools can also be used.
The `ghostty +crash-report` CLI command can be used to list any crash reports.
A future version of Ghostty will show you the contents of the crash report
directly in the terminal.

To send the crash report to the Ghostty project, you can use the following
CLI command using the [Sentry CLI](https://docs.sentry.io/cli/installation/):

```shell-session
SENTRY_DSN=https://e914ee84fd895c4fe324afa3e53dac76@o4507352570920960.ingest.us.sentry.io/4507850923638784 sentry-cli send-envelope --raw <path to ghostty crash>
```

> [!WARNING]
>
> The crash report can contain sensitive information. The report doesn't
> purposely contain sensitive information, but it does contain the full
> stack memory of each thread at the time of the crash. This information
> is used to rebuild the stack trace but can also contain sensitive data
> depending on when the crash occurred.
