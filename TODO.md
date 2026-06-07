# TODO

## Bugs

- [ ] **CMD unicode rendering** — CMD uses Windows code pages (incorrect rendering); Git Bash uses UTF-8 (correct). Investigate ConPTY unicode mode and `ENABLE_VIRTUAL_TERMINAL_PROCESSING` interaction with font rendering.
- [ ] **Multi-instance crash** — second nimmux instance conflicts with daemon PTY sessions (same data sockets). Fix: Windows named mutex to enforce single GUI instance.

## Features

- [ ] **Scroll wheel support** — scroll terminal output with mouse wheel
- [ ] **Select to copy + MMB to paste** — click-drag selects text, middle mouse button pastes
