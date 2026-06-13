# eve-packages-windows

First-party **eve** packages for Windows instances — everything that runs **after**
the instance is reachable (RDP, and the Windows side of
rustdesk/nomachine/splashtop/sunshine).

> **Status: scaffold.** Packages are extracted here in v4.0 Phase 3, scaffolded
> from `eve-plugin-template`. See the v4.0 roadmap.

Each package declares its precise Windows version support via its manifest
`supports`; cross-platform tools are defined separately here from their Linux
counterparts (same id, disjoint `supports`).

MIT licensed.
