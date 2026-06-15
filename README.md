# eve-packages-windows

First-party **eve** packages for Windows instances — everything that runs **after**
the instance is reachable over RDP: the Windows halves of the dual-OS remote
desktop and streaming tools (Discord, NoMachine, RDP, RustDesk, Splashtop, Steam,
Sunshine, Xpra).

These 8 packages are the **windows-only** set split out of the dual-OS packages in
v4.0 Phase 3. Each declares `supports: {os_families: [windows]}` (several also
constrain `arches`), and eve never offers a package to an incompatible instance.
Each shares its `id` with the matching Linux half in
`eve-packages-linux`; the two halves declare disjoint `supports.os_families` and
eve merges them at load time into one logical package.

## Consumption

Pull this catalog into an eve checkout alongside the core:

```
eve pull github.com/fruwehq/eve-packages-windows
```

`eve pull` drops each `<id>/` package under `plugins/packages/` so eve discovers
it like any built-in. You do **not** clone this repo manually or vendor anything.

## How packages run

Every package is self-contained CONTENT — a manifest (`eve-plugin.yaml`) plus a
`commands/` and `provision/` tree. None of them ship their own entrypoint:
every command's `exec: scripts/package-plugin` resolves to the **core generic
dispatcher** at the consuming eve checkout's repo root
(`scripts/package-plugin`, which stays in eve). So a package is pure data — it
extracts verbatim and runs against whatever eve version you've checked out.

## Layout

```
<id>/
  eve-plugin.yaml        # manifest: supports, install steps, command execs
  commands/windows/      # per-OS command shims (status, down)
  provision/windows/     # per-OS provisioning scripts run by the dispatcher
```

## Conformance

`.github/workflows/conformance.yml` checks out this repo plus `fruwehq/eve` (for
the harness, schema, and the `scripts/package-plugin` dispatcher) and runs
`eve/scripts/plugin-test` against every `*/eve-plugin.yaml`.

MIT licensed.
