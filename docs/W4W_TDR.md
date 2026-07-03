# Warden for Windows (W4W) — Technical Decision Record

This document records the significant technical decisions behind W4W and the reasoning for each. The implementation specification is `W4W_PRD.md`; this record explains *why* that design is what it is, including alternatives that were evaluated and rejected.

Each decision is stated with its context, the options considered, the choice, and the consequences.

---

## TDR-1: Jail substrate — Podman containers over per-jail WSL2 distros

**Status:** Accepted. This is the foundational decision; the rest of the design follows from it.

### Context

W4W needs many lightweight, disposable, isolated environments ("jails") on a Windows host, each hosting an AI coding agent that may run autonomously ("YOLO mode"). The hard constraint is host-filesystem safety; the soft constraints are fast creation/teardown, low overhead, and a workflow that mirrors the original Linux `warden` (a Bash tool wrapping the Incus container manager).

### Options considered

1. **WSL2 imported distros, one per jail.** Each jail is its own Linux distribution imported via `wsl --import`, managed by a PowerShell wrapper around `wsl.exe`. Snapshots/clones via `wsl --export` / `--import` of a gold tarball.
2. **Rootless Podman containers on a single Fedora WSL2 host.** One Warden host distro runs Podman; each jail is a container stamped from a gold image, managed by a Bash `warden4w.sh` script run inside WSL.
3. **Multipass / Hyper-V full VMs per jail.** True VM-grade isolation per jail.
4. **Docker-inside-Incus (the original Linux warden model), ported.** Nested containers.

### Decision

**Option 2 — rootless Podman containers on one Fedora WSL2 host.**

### Rationale

The two serious contenders were the distro-per-jail model (1) and the Podman-container model (2). The comparison below is the core of this decision.

| Dimension | Distro-per-jail (WSL2) | Podman container (chosen) | Verdict |
|---|---|---|---|
| Jail unit | One imported WSL2 distro per jail | One rootless container per jail | Podman: lighter, denser |
| Creation speed | `wsl --import` of a full tarball | `podman run` from a gold image | Podman: near-instant |
| Management CLI | PowerShell wrapping `wsl.exe` | Bash wrapping `podman` | Podman: matches original warden ergonomics |
| Where commands run | Windows PowerShell | Inside the Warden host WSL shell | Podman: Linux-native, as intended |
| Host FS isolation | Per-distro ext4; requires disabling automount per distro to remove `/mnt/c` | No bind-mount ⇒ no `/mnt/c` by construction | Podman: isolation by default, not by configuration |
| Privilege on escape | Real distro user | In-jail root ↔ unprivileged host UID | Podman: stronger |
| Disposable vs. durable | Whole distro is durable; no clean split | Disposable container + durable named volume | Podman: clean, explicit split |
| Resource limits | Global `.wslconfig` only (whole utility VM) | Per-jail `--memory` / `--cpus` | Podman: genuine per-jail control |
| Delete safety | `wsl --unregister` destroys the project with the distro | `podman rm` spares the volume by default | Podman: safer default |
| Provisioning | Per-distro provisioning script | One gold image + dotfiles repo | Podman: build once, reuse |

Option 3 (full VMs) was rejected: it gives the strongest isolation but at heavy cost in RAM, startup time, and density — the opposite of "many cheap disposable jails," and overkill given that rootless Podman already contains the host adequately (see TDR-2).

Option 4 (Docker-inside-Incus, nested) was rejected outright: nested virtualization proved unreliable on the target hardware, and it is precisely the problem this design avoids. Podman on the single WSL2 kernel needs no nesting.

The decisive factors for Podman over distro-per-jail were: **isolation is a property of the design rather than something switched on per distro** (no bind-mount means no host door, versus remembering to disable automount on every distro); the **clean disposable/durable split** (throwaway container + persistent volume) that makes upgrades and resets trivial; **per-jail resource limits**; a **safer delete default** (project survives jail deletion); and a **return to the original warden's Bash/CLI ergonomics** instead of a PowerShell detour.

### Consequences

- All jails share one Linux kernel (the WSL2 utility VM's). Isolation is container-grade, not VM-grade — accepted, see TDR-2.
- The project must live on a named volume, not the container layer, for durability (TDR-4).
- The management tool is Bash, run inside WSL, not PowerShell.
- A gold-image build step is introduced (TDR-6).

---

## TDR-2: Accepting container-grade isolation for a YOLO agent

**Status:** Accepted.

### Context

Container isolation is weaker than VM isolation: all jails share one kernel. The threat model is an AI agent running with broad autonomy that could, through error or adversarial input, attempt to damage the host.

### Decision

Container-grade isolation via **rootless** Podman is sufficient for this threat model.

### Rationale

Host-filesystem safety rests on two independent properties, either of which alone blocks the primary risk:

1. **No door.** A fresh container inherits no bind-mount of any host path. Inside a jail, `ls /mnt/c` fails — there is no route to the Windows or WSL host filesystem. Isolation comes from *not mounting* host paths, not from permissions that could be misconfigured.
2. **No privilege on escape.** Rootless Podman maps in-container `root` to the invoking unprivileged host user (validated: in-jail `root` ↔ host UID 1000 via `podman top <jail> user huser`). A container breakout therefore lands as an ordinary host user, not host root.

The residual risk is a kernel-level exploit that both escapes the container *and* escalates — a materially higher bar than the "careless/overreaching agent" this tool targets. Full VMs would close even that gap, but at a density and speed cost judged not worth it here (TDR-1, Option 3).

### Consequences

- Jails are not isolated from *each other* by default (shared kernel, shared network). Acceptable; the goal is host protection, not inter-jail secrecy.
- Granting an agent in-jail root (TDR-8) does not compromise host safety, which unlocks the YOLO sudo trade-off.

---

## TDR-3: Base distribution — Fedora

**Status:** Accepted.

### Context

The gold image and Warden host need a base Linux distribution. The original warden targeted a Debian/Ubuntu (`apt`) family.

### Decision

**Fedora** (Fedora 44 validated), using `dnf`.

### Consequences

- Provisioning uses `dnf`. The Fedora *container* image is deliberately minimal, which reinforces the "bake tools into the gold image" principle (TDR-6) — expected tools like `python3` are absent by default and must be added explicitly.
- Fedora expects systemd; where the Warden host needs it, WSL's systemd support is enabled.

---

## TDR-4: Project on a named volume; container is disposable

**Status:** Accepted.

### Context

A jail's filesystem must distinguish throwaway state (the environment) from durable state (the user's project), so jails can be freely destroyed and rebuilt.

### Decision

The project lives on a **named Podman volume** mounted at `/home/dev/project`. The container layer is **disposable**.

### Rationale

Validated by hand: anything written to the container's own filesystem is destroyed by `podman rm`; anything on a named volume survives and re-attaches to a new container. `podman rm` never removes mounted volumes. This yields a clean mental model — jails are cattle, the volume is the pet — and makes both deletion-safety (TDR-5) and gold-image upgrades (TDR-7) straightforward.

The volume's backing directory is resolved via `podman volume inspect --format '{{.Mountpoint}}'` and never hardcoded; rootless, it lives under `~/.local/share/containers/storage/volumes/<vol>/_data`, a normal Linux path in the Warden host that the host can open in VS Code.

### Consequences

- Host-side review targets the volume's Mountpoint, not a container path.
- `$HOME` state *outside* the project is disposable — which is why dotfiles are kept reproducible from a repo (TDR-6) rather than persisted, and why upgrade re-applies them (TDR-7).

---

## TDR-5: Delete safety — `rm` spares the volume

**Status:** Accepted.

### Decision

`delete` removes only the container (`podman rm -f`); the project volume is retained and can only be destroyed by a separate, deliberate `podman volume rm`, behind a warning that offers to `git push` / export first.

### Rationale

Because the project lives on the volume (TDR-4), destroying a jail no longer risks project data — a materially safer default than a model where deleting the jail deletes the work. The warning exists for the deliberate volume-removal case.

---

## TDR-6: Configuration split — gold image bakes binaries, dotfiles repo carries config

**Status:** Accepted.

### Context

Jails need a consistent shell/editor environment. Setup divides into heavy/network-bound work (installing binaries, downloading editor plugins) and lightweight config (rc files, themes, overrides). The heavy work should not repeat per jail; the config should be versioned and updatable.

### Decision

- **Bake into the gold image:** binaries and heavy/network setup — zsh, the oh-my-posh binary, the two zsh plugin binaries (cloned to a fixed `/usr/share/zsh-plugins/`), Neovim + the LazyVim base with plugins **pre-synced headless at build time**, language runtimes, and the `ENV SHELL=/bin/zsh` fix. Plus a minimal fallback `.zshrc`.
- **Keep in a dedicated dotfiles git repo:** the real `.zshrc`, oh-my-posh config, LazyVim overrides (`lua/config/`, `lua/plugins/` only), and aliases, applied by an idempotent `install.sh` (symlink-with-backup).
- **Apply at create:** clone the repo *inside* the jail and run `install.sh` — no host path mounted, preserving containment.

### Rationale

"Baked binaries, config in repo" puts the slow, deterministic work in the image (built once, reused instantly) and the fast, frequently-edited work in version control. Pre-syncing LazyVim plugins headless at build time means jails start ready with no first-launch download. Baking plugins to a fixed path lets the repo's `.zshrc` source them unconditionally. Cloning the repo in-jail rather than mounting it keeps the containment boundary intact.

### Consequences

- Editor/shell config is reproducible from the repo, not persisted per jail — this is what makes gold-image upgrades clean (TDR-7).
- The install model is symlink-with-backup and idempotent: re-runs are no-ops on already-correct links; replaced files are backed up with a timestamp. The same script serves the future `dotfiles update`.

---

## TDR-6a: Prompt/shell stack — oh-my-posh + native zsh, not oh-my-zsh

**Status:** Accepted. (A sub-decision of TDR-6, significant enough to record separately.)

### Context

The original plan considered using both oh-my-zsh (for plugins/completions) and oh-my-posh (for the prompt). In practice these two fight over prompt ownership — oh-my-zsh installs its own theme/prompt that competes with oh-my-posh, the classic gotcha.

### Decision

Drop oh-my-zsh entirely. Use **oh-my-posh** for the prompt and **native zsh** for completions and plugins.

### Rationale

Removing oh-my-zsh **dissolves** the prompt-ownership conflict rather than working around it: with no framework setting `PROMPT`, oh-my-posh is the uncontested driver via a single guarded `eval "$(oh-my-posh init zsh)"`. Native zsh covers what was actually wanted from oh-my-zsh:

- Completions via `compinit` plus a couple of `zstyle` rules (menu select, case-insensitive matching) — the behavior people miss most.
- The two standalone plugins (`zsh-autosuggestions`, `zsh-syntax-highlighting`) sourced directly from the baked path.

The oh-my-posh theme is the built-in `default` — no vendored theme file, no network at init, containment-friendly.

### Consequences

- `zsh-syntax-highlighting` must be sourced **last** (it wraps the line editor) — a hard ordering constraint captured in the `.zshrc`.
- Less "batteries-included" than oh-my-zsh, but far simpler to reason about and free of the prompt conflict.

---

## TDR-7: Gold-image upgrades via re-stamp (`upgrade <name> [image]`)

**Status:** Accepted.

### Context

When the gold image changes, existing jails should be able to move to it without losing project data or requiring manual migration.

### Decision

Provide `upgrade <name> [image]`: stop the jail, `podman rm` the disposable container, `podman run` a fresh same-named container with the same volume re-mounted on the target image, then re-clone the dotfiles repo and re-run `install.sh`. The optional `[image]` defaults to `warden4w/gold:latest`; an explicit tag also covers re-stamping on the *same* image to reset a polluted disposable layer.

### Rationale

Durable state lives in three places: on the project volume (survives `rm`, re-attaches — free), baked in the image (updated by stamping the new image — the point), and in `$HOME` outside the project (on the disposable layer — destroyed by `rm`). The third bucket is why upgrade must be a **re-stamp with dotfile re-application**, not a bare re-mount. `$HOME` config is kept reproducible from the repo (TDR-6) rather than persisted on a volume, because mounting a volume over `/home/dev` would shadow the baked LazyVim base and fallback `.zshrc`.

`upgrade` is named for intent ("move this jail to a newer image"), which reads better next to `delete` than a mechanism-named `recreate`. A single verb with an optional image argument absorbs the "reset on same image" case, avoiding a separate `reset` command.

### Consequences

- Upgrades and resets are the same operation, differing only in the image tag passed.
- The disposable nature of `$HOME` is an explicit, documented property, not a surprise.

---

## TDR-8: Package installation and the YOLO sudo trade-off

**Status:** Accepted.

### Context

Jails run as unprivileged `dev` with no sudo. A YOLO-mode agent may need to `dnf install` unattended, which must not require a password.

### Decision

Three paths, preference-ordered: **bake it** into the gold image (preferred, durable); **`podman exec -u root`** from the Warden host for manual one-offs (passwordless, disposable); and **opt-in passwordless sudo** via `create --yolo`, which writes `dev ALL=(ALL) NOPASSWD:ALL` into that jail only.

### Rationale

Baking is preferred because it is durable, reviewed, and needs no runtime privilege. `podman exec -u root` is passwordless because in-jail root is just the remapped host UID (TDR-2), and is ideal for throwaway installs. Passwordless sudo for the agent is the true YOLO path: it lets the agent become in-jail root at will, which — critically — does **not** breach the host (still no door, still an unprivileged host UID on escape). It only weakens *intra-jail* protection: the agent can trash its own disposable container. Because jails are throwaway (TDR-4) and the project is on a volume, that is an acceptable trade. Making it an opt-in per-jail flag keeps the weaker boundary a deliberate choice rather than a default.

### Consequences

- Non-YOLO jails remain fully locked down (no sudo).
- The security guarantee is explicitly *host* protection, which is structural and independent of whether the agent has in-jail root.

---

## TDR-9: Networking — IPv4-pinned port publishing

**Status:** Accepted.

### Context

Rootless Podman on WSL uses `pasta` networking. Services in a jail must be reachable from a host browser.

### Decision

Publish ports with **`-p 127.0.0.1:<host>:<container>`**, and require in-jail services to bind **`0.0.0.0`**.

### Rationale

Validated by hand: with `pasta`, `localhost` resolves to IPv6 `::1` first, and the bare `-p <host>:<container>` publish resets over IPv6 (`ERR_EMPTY_RESPONSE` in a browser, connection reset over IPv6 in curl). Pinning the publish to the IPv4 loopback fixes this and, as a bonus, binds the port to loopback only (not exposed to the wider network). Separately, a service bound to the container's own `127.0.0.1` is invisible to Podman's forward, so services must bind `0.0.0.0`.

### Consequences

- Both rules are baked into the `create`/publish flow and documented, since either omission produces a confusing "port looks mapped but doesn't work" failure.

---

## Decisions deferred / open

- **Zellij** integration in `connect` — planned; whether Zellij is baked into the gold image is not yet locked.
- **AI agent wiring** inside jails (which agents, baked vs. installed, how API keys are supplied at runtime) — planned, not yet specified.
- **`dotfiles update <name>`** as a standalone command (refresh config without changing the image) — noted as future; `upgrade` already re-applies dotfiles.
- **Per-jail network isolation** — not implemented; would require Podman network configuration if a future need arises.
