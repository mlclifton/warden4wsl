# TIL — Rootless Podman jails on WSL2 (Fedora)

Focused notes from setting up Podman-container jails by hand on a Fedora 44 WSL2 distro (Podman 5.8.2). Each entry is a question I actually hit, with the short answer.

---

### Why doesn't `code <path>` work from my WSL2 terminal?

You get `cannot execute binary file: Exec format error` pointing at `/mnt/c/.../Code.exe`. The `code` on your PATH resolved to the **Windows** VS Code executable, and WSL tried to run a Windows `.exe` as a Linux binary. The proper Linux-side shim (installed by the VS Code WSL extension under `~/.vscode-server/.../bin/remote-cli/code`) isn't winning on PATH from a plain terminal.

Fixes, easiest first:
- Drive it from VS Code on Windows: `F1` → **WSL: Connect to WSL** → **File: Open Folder**. No CLI needed.
- Run `code .` from an **integrated terminal inside a remote VS Code window** — there the shim resolves correctly.
- Only if you want it from a plain terminal: prepend the server's `remote-cli` dir to PATH in your shell rc (resolve it dynamically — the path contains a commit hash that changes on update).

---

### Why does my published port work with `curl 127.0.0.1:8080` but not `localhost:8080`?

Rootless Podman on WSL uses `pasta` networking. `localhost` resolves to IPv6 `::1` first; the bare `-p 8080:8000` publish doesn't serve that cleanly, so the connection is reset — `ERR_EMPTY_RESPONSE` in the browser, `Connection reset by peer` over IPv6 in curl. IPv4 `127.0.0.1` works fine.

Fix: pin the publish to the IPv4 loopback — `-p 127.0.0.1:8080:8000`. Bonus: this also binds the port to loopback only, so it isn't exposed to your wider network.

---

### Why can't my published service be reached even though the port mapping looks right?

The service inside the container must listen on `0.0.0.0` (all interfaces), not the container's own `127.0.0.1`. A localhost-only bind is invisible to Podman's port forward. (`python3 -m http.server` defaults to `0.0.0.0`, which is why it worked.)

---

### If a container is "root", can it touch my Windows/WSL files?

No — two independent reasons:
1. **No door:** a fresh container has its own mount namespace and inherits no `/mnt/c`. Inside a jail, `ls /mnt/c` returns *No such file or directory*. Isolation comes from not bind-mounting host paths, not from permissions.
2. **No privilege even on escape:** rootless Podman maps in-container `root` to your unprivileged host user. `podman top <jail> user huser` shows in-jail `root` ↔ host UID `1000`. A breakout lands as an ordinary user, not system root.

---

### If in-jail root is harmless to the host, can I just give the agent sudo?

Yes, deliberately — that's the YOLO trade. `dev` has no sudo by default, so an unattended agent can't `dnf install`. Opt a single jail in by writing `dev ALL=(ALL) NOPASSWD:ALL` to `/etc/sudoers.d/dev` (this is what `create --yolo` does). It lets the agent become in-jail root at will, which does **not** breach the host — still no door, still an unprivileged host UID on escape (see above). All it weakens is *intra-jail* protection: the agent can trash its own disposable container. Since the container is throwaway and the project's on a volume, that's a fine trade — just keep it opt-in and per-jail, not a default.

---

### How do I install something in a running jail without sudo inside it?

From the **Warden host**, enter the jail as root — no password needed:

```bash
podman exec -u root <jail> dnf install -y <pkg>
```

This works passwordless because in-jail root is just your remapped host UID; you're not escalating anything. But the install lands on the **disposable layer** and vanishes on the next `rm`/`upgrade`. Use it for genuine throwaways; anything you need repeatedly belongs baked into the gold image instead.

---

### What survives when I delete a container, and what doesn't?

- Anything written to the container's own filesystem (e.g. `/root`, an in-container `dnf install`) lives in the **disposable layer** and is destroyed by `podman rm`.
- Anything on a **named volume** (`-v myvol:/path`) survives. Delete the container, mount the same volume into a brand-new one, and the data is still there.

`podman rm` never removes mounted volumes. This is why the project lives on a volume and jails are treated as throwaway.

---

### Wait — so my `~/.zshrc` and shell history don't survive an upgrade?

Correct, and this one bites if you forget it. There are **three** durability buckets, not two:
1. **Project volume** (`/home/dev/project`) — durable, re-attaches for free.
2. **Baked into the image** (tooling, plugins, LazyVim base) — updated *because* you're stamping the new image; that's the point of upgrading.
3. **`$HOME` outside the project** (`~/.zshrc`, nvim overrides, aliases, `~/.zsh_history`) — lives on the **disposable layer** and is destroyed by `rm`.

Bucket 3 is the trap. Don't "fix" it by mounting a volume over `/home/dev` — that shadows the baked LazyVim base and fallback `.zshrc`. Instead keep `$HOME` config reproducible from the dotfiles repo, and make `upgrade` a **re-stamp**: `rm` the container, `run` a fresh one on the new image with the same project volume, then re-clone dotfiles and re-run `install.sh`. `$HOME` is intentionally disposable; the repo is the source of truth.

---

### Where does a named volume actually live on disk?

```bash
podman volume inspect <vol> --format '{{.Mountpoint}}'
```

Rootless, it's under `~/.local/share/containers/storage/volumes/<vol>/_data`. That's a normal Linux path in your WSL distro, so you can read/edit it from the WSL shell or VS Code (and via `\\wsl.localhost\<distro>\...` from Windows). Treat the exact path as an implementation detail — always resolve it via `inspect`, don't hardcode it.

---

### Can I edit project files from the host while the agent runs in the jail?

Yes. The volume's backing directory and the jail's mounted path are the same bytes, so edits from VS Code (host side) and the agent (in jail) both see each other immediately via native inotify. That two-way door exists **only** on the project path — everything else in the jail stays sealed, which is where the containment comes from.

---

### Why did files I `podman cp` into a jail end up owned by root?

`podman cp` lands files as **root** regardless of the container's default user, so a repo you copy in for `dev` to use is owned wrong and may be unwritable under `dev`. Fix ownership right after the copy:

```bash
podman cp ~/warden-dotfiles <jail>:/home/dev/warden-dotfiles
podman exec -u root <jail> chown -R dev:dev /home/dev/warden-dotfiles
```

This only matters for the local-iteration shortcut (copying an uncommitted repo in). The intended path — `git clone` *inside* the jail as `dev` — gets ownership right for free, so prefer it once the repo has a remote.

---

### Why is `python3` (and other tools) missing in the Fedora container?

The Fedora **container** image (`VARIANT="Container Image"`) is deliberately minimal — much leaner than a full WSL distro. Tools you expect aren't there. Don't `dnf install` them per jail (they vanish on `podman rm`); bake them into the gold image once so every jail is born ready.

---

### Why does oh-my-posh render oddly, and why is `$SHELL` blank in the container?

The minimal Fedora container doesn't set `$SHELL`, and oh-my-posh (plus other `$SHELL`-inspecting tools) misbehaves when it's empty. Bake the fix into the Containerfile:

```dockerfile
RUN useradd -m -s /bin/zsh dev
ENV SHELL=/bin/zsh
```

Setting the login shell on `useradd` isn't enough on its own here — the explicit `ENV SHELL` is what oh-my-posh actually reads at init.

---

### oh-my-zsh and oh-my-posh keep fighting over the prompt — how do I fix it?

Don't reconcile them — drop one. oh-my-zsh installs its own theme/prompt that competes with oh-my-posh for `PROMPT`; running both is the classic gotcha. The clean answer is to **remove oh-my-zsh entirely**: let oh-my-posh own the prompt (a single guarded `eval "$(oh-my-posh init zsh)"`), and get everything you actually wanted from oh-my-zsh out of **native zsh** instead:

- Completions: `compinit` plus a couple of `zstyle` rules (menu select, case-insensitive matching).
- Plugins: source `zsh-autosuggestions` and `zsh-syntax-highlighting` directly from their baked path.

With no framework setting `PROMPT`, the conflict doesn't get worked around — it stops existing.

---

### My zsh-syntax-highlighting isn't coloring anything — ordering?

Almost certainly ordering. `zsh-syntax-highlighting` **must be sourced last** in your `.zshrc` — it wraps the line editor, so anything sourced after it isn't hooked. Put it after autosuggestions, after `compinit`, and after the oh-my-posh init.

---

### When I point oh-my-posh at my own theme, why does `~` fail?

oh-my-posh wants a **full path** to `--config`, not a `~`-relative one; the tilde isn't expanded in the context it reads. Use the resolved absolute path:

```zsh
eval "$(oh-my-posh init zsh --config "$HOME/warden-dotfiles/oh-my-posh/warden.omp.json")"
```

`$HOME` expands fine (it's a shell variable); a bare `~` inside the quoted arg does not.

---

### Why did baking LazyVim into the gold image leave it broken / root-owned?

Plugin pre-sync has to run **as `dev`, after `USER dev`** — otherwise the clone and `Lazy! sync` run as root and leave `~/.config/nvim` and the plugin tree owned by root, so `dev` can't use or update them. Order in the Containerfile matters:

```dockerfile
USER dev
RUN git clone --depth 1 https://github.com/LazyVim/starter /home/dev/.config/nvim \
  && rm -rf /home/dev/.config/nvim/.git \
  && nvim --headless "+Lazy! sync" +qa || true
```

Doing the headless sync at build time also bakes the heavy plugin download into the image, so jails start ready with no first-launch fetch.

---

### What's the `WARN ... "/" is not a shared mount` message?

A harmless WSL quirk about root mount propagation. Rootless containers still run fine. Silence it if it bothers you with `sudo mount --make-rshared /` (or a systemd unit to persist it across restarts).

---

### `podman ps` vs `podman ps -a`?

`podman ps` shows only **running** containers; `podman ps -a` includes **stopped** ones too. A container you `exit` out of is stopped (still listed under `-a`), not deleted — restart it with `podman start -ai <name>` and its files are intact.

---

### The one-time setup that actually mattered

```bash
sudo dnf install -y podman          # the only command needing sudo
podman run --rm hello-world         # rootless sanity check (run as your user)
```

If the sanity check passes as your normal user, rootless Podman is working and the whole jail approach is sound on your machine. For jails that should keep running after you close your WSL session, also set `loginctl enable-linger <user>`.
