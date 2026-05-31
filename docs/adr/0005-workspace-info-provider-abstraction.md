# 0005 — Workspace Info Provider Abstraction

Date: 2026-05-31  
Status: Accepted

## Context

Each pane displays contextual information in the sidebar: current working directory, git branch, and listening ports. For local panes this data is obtained by interrogating the local OS (via `/proc`, `ss`, `git`, `netstat`, `wmic`). 

A planned feature is SSH workspaces (`nimmux ssh user@remote`), where the shell runs on a remote host. In that case the CWD, git branch, and ports are only meaningful on the remote machine and cannot be read from the local OS. A remote daemon process (the "nimmux agent") will run on the SSH host and expose this information over the existing IPC protocol.

## Decision

Pane workspace information (CWD, git branch, listening ports) is always associated with a **source label** that identifies where the data came from:

- `"local"` — data was read from the local machine.
- `"ssh://user@host"` — data was read from a remote nimmux agent over an SSH-tunnelled IPC connection.

`PaneInfo` in `renderer.nim` carries a `source: string` field. The sidebar may display it when it is not `"local"` (i.e., it is suppressed for ordinary local panes to avoid visual noise, and shown as a host badge for SSH panes).

The local subprocess functions (`getGitBranch`, `getPanePorts`) remain as the **local provider**. When SSH workspaces land, a **remote provider** will query the daemon and produce the same data with a different source label. The sidebar and session code are provider-agnostic.

## Consequences

- `PaneInfo` gains `source: string`; all existing call sites pass `"local"`.
- Future SSH pane states carry a connection reference; their provider populates `source` with the remote host string.
- No further changes to `renderer.nim` or the sidebar drawing code are required when SSH lands — only a new provider implementation and a routing decision in the main loop.
- The IPC protocol (already planned for MVP 1.1) doubles as the local↔remote data channel; the remote daemon reuses the same message schema.
