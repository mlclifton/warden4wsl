# Warden for Windows (W4W) — Product Requirements Document

## Overview

**Warden for Windows (W4W)** helps set up and manage AI coding sandboxes — "jails" — on a Windows host. The Warden looks after the jail. Each jail is an isolated environment in which an AI coding agent (OpenCode, Gemini CLI, etc.) can operate, including in autonomous "YOLO mode," without being able to damage the host filesystem.

The design runs a single **Fedora WSL2 distribution** (the "Warden host") that hosts **rootless Podman**. Each jail is a Podman **container** stamped from a **gold image** and managed by a Bash script, `warden4w.sh`, run from inside the Warden host. The project under development lives on a durable **named volume**; the container itself is disposable.

This document is the implementation specification. The rationale for the architecture — including alternatives evaluated and why they were rejected — is recorded separately in `W4W_TDR.md`.

## Goals & Success Criteria

Establish a secure, performant, flexible development environment for working with AI coding agents on a Windows host. The setup must balance:

- **Strict isolation** — an agent in YOLO mode must not be able to reach or damage the host filesystem.
- **Usability** — fast, native-feeling file review from host-side GUI tools (VS Code), quick jail creation and teardown, and familiar terminal workflows.

Concrete success criteria:

- A jail is created from the gold image in seconds, with no per-jail provisioning.
- From inside a jail, there is no path to the Windows or WSL host filesystem.
- A rogue or careless agent that gains root *inside* a jail still cannot touch the host.
- Project files are editable from the host (VS Code) and the agent simultaneously, with instant two-way visibility.
- Deleting a jail never destroys project work by accident.
- The gold image can be updated and existing jails migrated to it without hand-migrating project data.

## Platform Prerequisites

- Windows 10 (21H2+) or Windows 11 — any edition (Home, Pro, Enterprise, Education). WSL2 runs on all of them.
- WSL2 installed and set as default (`wsl --set-default-version 2`).
- Virtualization enabled in firmware.
- A **Fedora WSL2 distribution** as the Warden host (Fedora 44 validated).
- **Rootless Podman** installed in that distribution (`sudo dnf install -y podman`; Podman 5.8.2 validated). This is the only step requiring `sudo`.
- VS Code with the WSL remote extension (host-side review tool).
- The user operates from a **WSL Bash command line**.

---

## Core Requirements

- **Security & Isolation.** The agent operates within a confined boundary that prevents accidental or malicious damage to the host. Containment rests on two independent properties:
  1. **No door** — a jail inherits no bind-mount of any host path. There is no `/mnt/c` and no route to the Windows or WSL host filesystem from inside a jail.
  2. **No privilege on escape** — rootless Podman maps in-jail `root` to an unprivileged host UID (validated: in-jail `root` ↔ host UID 1000 via `podman top`). Even a container breakout lands as an ordinary host user, never host root.
  Jails run as an unprivileged `dev` user by default and are not network-isolated from each other.

- **Experimentation.** Rapid creation, destruction, and restoration of environments. Jails are stamped from the gold image (`podman run`), destroyed with `podman rm`, and their durable state re-attached via named volumes. The container layer is disposable; the project volume is durable.

- **Performance.** Near-native CPU and I/O for files on the Linux side (the volume's backing store on ext4 in the Warden host). Cross-boundary I/O (Windows reading `\\wsl$`) is avoided for build/agent workloads.

- **Host Interaction — Web.** A host browser reaches services in a jail at `http://localhost:<port>`, subject to two rules (see Networking): publish with the IPv4-pinned form, and bind the in-jail service to `0.0.0.0`.

- **Host Interaction — Files.** The project lives on a named volume mounted at `/home/dev/project`. The host reviews and edits it via VS Code WSL remote, opening the volume's backing directory directly — native inotify, instant two-way updates between host and agent.

- **Network Control.** Controlled internet access for package installation and API calls. Egress restriction is applied inside the jail or via Podman network configuration; Windows Firewall provides host-level restriction.

- **Tooling Familiarity.** Standard terminal workflows — zsh with an oh-my-posh prompt and native-zsh completions/plugins, Neovim (LazyVim), and the AI agents — all available in every jail.

- **Automation.** The full lifecycle is scriptable via `warden4w.sh`, a Bash wrapper around `podman` run from inside the Warden host.

- **Configuration.** On creation the user can set per-jail resource limits (Podman `--memory`, `--cpus`) and publish ports; sensible defaults apply otherwise.

---

## Architecture

A single **Fedora WSL2 distribution (the Warden host)** runs **rootless Podman**. Each jail is a Podman **container** stamped from the gold image `warden4w/gold:latest`, with the project on a durable **named volume**. The lifecycle is driven by `warden4w.sh` from inside WSL.

### A. Jail Strategy

- **Unit:** one rootless Podman container per project = one jail; all jails on one Warden host.
- **Base image:** the gold image, built from a `Containerfile` `FROM fedora:44`. The Fedora *container* image is deliberately minimal — expected tools (e.g. `python3`) are absent by default — so everything a jail needs is baked into the gold image once, never installed per jail (per-jail installs land on the disposable layer and vanish on `rm`).
- **Isolation:** rootless container namespaces; agent runs as unprivileged `dev`; in-jail root maps to an unprivileged host UID.
- **Resource limits:** per-jail via `--memory` / `--cpus`; a global ceiling for the whole Warden host via `.wslconfig`.

### B. Gold Image (Containerfile)

Built once, rebuilt when the baseline changes. Composition (validated by hand):

- `FROM fedora:44` (pinned).
- **Base tooling in one cleaned `RUN` layer:** `zsh`, `git curl wget`, `python3 python3-pip`, `nodejs npm`, `neovim`, `ripgrep fd-find` (LazyVim pickers need them), `util-linux-user`; `dnf clean all` and cache removal in the same `RUN` so the layer stays small.
- **oh-my-posh binary** installed to `/usr/local/bin` (on PATH for all users).
- **zsh plugins baked** (`zsh-autosuggestions`, `zsh-syntax-highlighting`) cloned `--depth 1` to a fixed system path `/usr/share/zsh-plugins/`, so the dotfiles `.zshrc` sources them unconditionally. Binaries are baked; their configuration lives in the dotfiles repo.
- **Unprivileged user:** `useradd -m -s /bin/zsh dev`.
- **`ENV SHELL=/bin/zsh`** — fixes the blank `$SHELL` that otherwise trips oh-my-posh and `$SHELL`-inspecting tools.
- **Neovim + LazyVim, pre-synced headless at build time:** clone the LazyVim starter to `~/.config/nvim`, detach its `.git`, then run `nvim --headless "+Lazy! sync" +qa` **as `dev`** (after `USER dev`, so all config and plugin files are `dev`-owned). This bakes the heavy plugin download into the image; jails start ready.
- **`WORKDIR /home/dev/project`** (the named-volume mount point) and **`CMD ["/bin/zsh", "-l"]`** — the login shell (`-l`) forces the rc chain to load so dotfiles apply.

### C. Dotfiles (configuration)

Configuration is a **dedicated warden dotfiles git repo** — the single source of truth — kept separate from the gold image.

- **Baked into the gold image:** binaries and heavy/network setup — the zsh plugin binaries, the oh-my-posh binary, the Neovim + LazyVim base with plugins pre-synced, language runtimes, and the `ENV SHELL` fix. A minimal fallback `.zshrc` also ships, so a jail that never receives dotfiles still works (falling back to zsh's default prompt).
- **In the dotfiles repo:** the real `.zshrc` (oh-my-posh init + plugin sourcing + completions + aliases), oh-my-posh configuration, and LazyVim **overrides only** (`lua/config/`, `lua/plugins/`; the base stays baked). An idempotent `install.sh` symlinks each config into place and backs up (timestamped) anything real it replaces; re-running is a no-op on already-correct links.
- **Prompt & shell stack:** **oh-my-posh** drives the prompt; **native zsh** provides completions and plugins (no oh-my-zsh). With no framework competing for `PROMPT`, oh-my-posh is the sole prompt driver via a single guarded `eval "$(oh-my-posh init zsh)"`. The theme is oh-my-posh's built-in `default` (no vendored theme file, no network). Completions come from `compinit` plus `zstyle` rules (menu select, case-insensitive matching). **`zsh-syntax-highlighting` must be sourced last** — it wraps the line editor.
- **Applied at `create`:** the dotfiles repo is **cloned inside the jail** (from git, as `dev`) and its `install.sh` run — no host path mounted, so containment is preserved.
- **Update semantics:** new jails get the latest dotfiles at create; existing jails stay pinned at their creation state until explicitly refreshed (see `upgrade` and `dotfiles update`).

### D. Filesystem & Persistence

- **Project:** on a named Podman volume mounted at `/home/dev/project` — durable, survives `podman rm`, re-attaches to new containers.
- **Container layer:** disposable. Never keep durable state on the container's own filesystem.
- **Host access:** VS Code WSL remote opens the volume's backing directory (resolved via `podman volume inspect --format '{{.Mountpoint}}'` — never hardcoded; rootless, it sits under `~/.local/share/containers/storage/volumes/<vol>/_data`). The backing directory and the jail's mounted path are the same bytes, so host edits and in-jail agent edits see each other immediately via native inotify.
- **Host filesystem protection:** no host path is bind-mounted into a jail. No `/mnt/c` = no door. The project volume is the only two-way path.

### E. Networking & Discovery

- **Connectivity:** rootless Podman via `pasta`; jails share the Warden host's networking.
- **Port publishing (two rules, both validated):**
  1. Publish with **`-p 127.0.0.1:<host>:<container>`** — the IPv4-pinned form. The bare form resets over IPv6 `::1` under `pasta` (browser shows `ERR_EMPTY_RESPONSE`). Pinning also binds the port to loopback only, so it isn't exposed to the wider network.
  2. The in-jail service must bind **`0.0.0.0`**, not the container's own `127.0.0.1`, or Podman's forward can't see it.
  With both, `http://localhost:<port>` on the host reaches the jail.
- **Inter-jail isolation:** none by default.

### F. Identity & Secrets

- **Git access:** SSH agent forwarding / host credential reuse via WSL; keys are never baked into the gold image. Dotfiles and project repos are cloned in-jail as `dev`.
- **Connect path:** `podman exec` into the running jail (no SSH hop), attaching an interactive login shell (`zsh -l`) so dotfiles load.
- **API keys:** passed via environment variables at jail entry or tmpfs files; never baked into the gold image.

### G. Installing Packages Inside a Jail

Jails run as unprivileged `dev`, which has no sudo by default, so installing packages in a running jail is a deliberate choice. Three paths, in order of preference:

- **Bake it (preferred).** Anything you repeatedly need belongs in the gold image. Add it to the Containerfile's `dnf install` layer, rebuild, and `upgrade` existing jails. The install is durable, reviewed, and deterministic, and never requires runtime sudo.
- **`podman exec -u root <jail> dnf install -y <pkg>` (manual one-off).** Rootless Podman lets you enter any jail as root from the Warden host with no password — in-jail root is just your remapped host UID. The install lands on the disposable layer and is gone on `upgrade`/`rm`; use it for throwaway needs.
- **Passwordless sudo for `dev` (opt-in, per-jail).** For agents that must install packages unattended in YOLO mode, `create --yolo` writes a passwordless-sudo rule (`dev ALL=(ALL) NOPASSWD:ALL` in `/etc/sudoers.d/dev`) into that jail only. This lets the agent become in-jail root at will. It does **not** breach the host — in-jail root is still an unprivileged host UID (no door, no privilege on escape) — but it weakens *intra-jail* protection: the agent can trash the disposable container. Since jails are throwaway and the project is on a volume, this is an acceptable, deliberately opt-in trade.

### H. Upgrading the Gold Image

A jail is `gold image (disposable) + project volume (durable)`. When the gold image changes, existing jails are migrated by re-stamping, not hand-migration, because durable state is separated from the image.

Durable state lives in three places; two ride along automatically on upgrade:

- **On the project volume** (`/home/dev/project`) — survives `rm` and re-attaches. Free.
- **Baked in the image** (tooling, plugins, LazyVim base, oh-my-posh binary) — updated because the new image is being stamped. The point of the upgrade.
- **In `$HOME` outside the project** (`~/.zshrc`, nvim overrides, aliases, `~/.zsh_history`) — lives on the **disposable layer** and is destroyed by `rm`. It does **not** ride along.

Because of the third bucket, `upgrade` is a **re-stamp**, not a bare re-mount: it re-clones the dotfiles repo in the new container and re-runs `install.sh` (idempotent, with backups), giving the new jail current dotfiles against the new image with the project untouched. `$HOME` config is kept reproducible from the repo rather than persisted on a volume — mounting a volume over `/home/dev` would shadow the baked LazyVim base and fallback `.zshrc`.

Flow:

```bash
podman stop <name>
podman rm <name>                        # destroys ONLY the disposable layer; volume survives
podman run -d --name <name> \
  -v <vol>:/home/dev/project \           # same volume, re-attached
  <image>                                # new (or pinned/same) image
# then, in the new container as dev: clone dotfiles repo + run install.sh
```

---

## Automation Workflow

`warden4w.sh`, run inside the Warden host, exposes:

1. **`create <name> [git_url] [--yolo]`**
   - Creates a named volume; stamps a jail from `warden4w/gold:latest` with the volume at `/home/dev/project`
     (`podman run -d --name <name> -v <vol>:/home/dev/project ... warden4w/gold:latest`).
   - Clones the dotfiles repo in-jail (as `dev`) and runs `install.sh`.
   - If `git_url` given, clones the project into `/home/dev/project` on the volume.
   - Publishes requested ports with the IPv4-pinned form.
   - `--yolo` grants `dev` passwordless sudo in this jail (off by default; see G).

2. **`connect <name>`** — `podman exec -it -u dev <name> zsh -l`: direct entry, interactive login shell so dotfiles load. Optionally attaches Zellij.

3. **`start <name>` / `stop <name>`** — `podman start` / `podman stop`. A stopped jail's files are intact (`podman ps -a` lists it). For jails that must keep running after the WSL session closes, `loginctl enable-linger <user>`.

4. **`delete <name> [--yes]`** — `podman rm -f <name>` destroys the disposable container. The named volume is **not** removed by `rm`; deleting it is a separate, deliberate step (`podman volume rm`). The prompt warns before removing a volume and offers to `git push` / export first.

5. **`list`** — `podman ps -a` filtered to warden jails, with state.

6. **`info <name>`** — jail state, published ports, the project volume's Mountpoint (via `podman volume inspect`), and the VS Code review path.

7. **`image build` / `image list` / `image delete`** — `image build` = `podman build -t warden4w/gold:latest .` from the gold-image build context; the others manage local Podman images.

8. **`upgrade <name> [image]`** — re-stamps an existing jail on a newer gold image while preserving its project (see H). The optional `[image]` selects the target image, defaulting to `warden4w/gold:latest`; passing an explicit tag covers upgrading to a pinned image and re-stamping on the *same* image to reset a polluted disposable layer.

9. **`dotfiles update <name>`** (future) — re-pull the dotfiles repo in-jail and re-run `install.sh` (idempotent). For refreshing dotfiles without changing the image; `upgrade` already re-applies them.

10. **`doctor`** — validates: Warden host present, rootless Podman working (`podman run --rm hello-world` as the user), gold image exists, VS Code WSL extension present. (The `WARN "/" is not a shared mount` message is harmless.)

11. **`help`** — prints usage.

---

## Validation Strategy

Much of the substrate is proven by hand (Fedora 44, Podman 5.8.2): rootless install and sanity check; filesystem isolation (no `/mnt/c`) and UID remap; disposable layer vs. durable volume; host-side volume access; IPv4-pinned port publishing with `0.0.0.0` bind; VS Code WSL-remote review; the gold image (tooling baked, runs as `dev`, independent per-jail filesystems); and the dotfiles repo (oh-my-posh prompt and both plugins live after `install.sh` in a login shell).

### Test Case: build a real project in a jail

1. **Create & clone** a real project into the named volume at `/home/dev/project`.
2. **Dotfiles:** `connect` drops into a `zsh -l` login shell with the oh-my-posh prompt and both plugins live (autosuggestions greyed-ahead; syntax highlighting coloring valid vs. invalid commands).
3. **Host review:** open the volume's Mountpoint via VS Code WSL remote; confirm native-speed, instantly-updating access, and that host edits appear in-jail immediately.
4. **Build:** run the project's build inside the jail.
5. **Isolation:** from inside the jail, confirm `ls /mnt/c` fails (no door) and `podman top <jail> user huser` shows in-jail root ↔ unprivileged host UID.
6. **Web:** start a dev server bound to `0.0.0.0`, publish with `-p 127.0.0.1:<port>:<port>`, confirm it loads at `http://localhost:<port>` in a host browser.
7. **Lifecycle:** `podman rm` the jail, confirm the volume and project survive, mount it into a fresh jail, confirm state is intact; then deliberately remove the volume and observe the warning.
8. **Upgrade:** rebuild the gold image, `upgrade` the jail, confirm the project is intact and dotfiles/tooling reflect the new image.

**Automated guide:** `validate_setup.sh` walks through the above.
