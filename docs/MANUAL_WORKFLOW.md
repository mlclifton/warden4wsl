# warden4w — Manual Workflow

Hand-run steps for the rootless-Podman-on-WSL2 jail model, based on what's been validated on Fedora 44 / Podman 5.8.2. Two parts: building the gold image, then stamping and entering a jail.

Assumes rootless Podman already works (`podman run --rm hello-world` succeeds as your normal user). If you want jails to survive closing the WSL session, run `loginctl enable-linger $USER` once.

---

## Part 1 — Build the Gold Image

The gold image bakes in tooling + shell binaries once so every jail is born ready. Config (dotfiles) is layered in at jail-setup time, not baked.

### 1. Prepare a build directory

```bash
mkdir -p ~/warden4w/gold && cd ~/warden4w/gold
```

### 2. Write the Containerfile

Base tooling goes in a single cleaned `RUN` layer; binaries and zsh plugins are baked; the `dev` user is unprivileged with zsh as login shell.

```dockerfile
FROM fedora:44

# Base tooling — one cleaned layer
RUN dnf install -y \
      zsh git curl python3 nodejs neovim ripgrep fd-find util-linux-user \
  && dnf clean all && rm -rf /var/cache/dnf

# oh-my-posh binary
RUN curl -s https://ohmyposh.dev/install.sh | bash -s -- -d /usr/local/bin \
  && chmod +x /usr/local/bin/oh-my-posh

# zsh plugins — baked binaries, config lives in the dotfiles repo
RUN mkdir -p /usr/share/zsh-plugins \
  && git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions \
       /usr/share/zsh-plugins/zsh-autosuggestions \
  && git clone --depth 1 https://github.com/zsh-users/zsh-syntax-highlighting \
       /usr/share/zsh-plugins/zsh-syntax-highlighting

# Unprivileged dev user, zsh login shell
RUN useradd -m -s /bin/zsh dev
ENV SHELL=/bin/zsh

# Jail marker — read by oh-my-posh to badge the prompt. Static "this is a jail"
# flag; the per-jail name is injected at run time (see Part 2) so the image
# stays name-agnostic.
ENV WARDEN_JAIL=1

# Headless LazyVim plugin pre-sync as dev (correct ownership)
USER dev
RUN git clone --depth 1 https://github.com/LazyVim/starter /home/dev/.config/nvim \
  && rm -rf /home/dev/.config/nvim/.git \
  && nvim --headless "+Lazy! sync" +qa || true

USER dev
WORKDIR /home/dev
```

### 3. Build and tag

```bash
podman build -t warden4w/gold:latest .
```

### 4. Validate the image

Run a throwaway container and confirm the shell stack activates on a login shell without manual steps:

```bash
podman run --rm -it warden4w/gold:latest zsh -l
```

You should see the oh-my-posh prompt, and autosuggestions + syntax highlighting active. `exit` when satisfied. Note: on a bare gold container the dotfiles aren't installed yet, so the prompt is whatever the baked defaults give you — full activation is proven once the dotfiles are in (Part 2).

---

## Part 2 — Stamp and Access a New Jail

A jail is a Podman container off the gold image, with the project on a **named volume** (durable) while the container layer stays disposable. Dotfiles are installed into the jail after creation.

Pick a jail name (used below as `<name>`) and set the project volume name to match.

### 1. Create the durable project volume

```bash
podman volume create <name>-project
```

### 2. Start the jail

Mount the volume at the project path. Publish ports pinned to IPv4 loopback (bare `-p` breaks under `pasta` over IPv6).

```bash
podman run -dit \
  --name <name> \
  -e WARDEN_JAIL_NAME=<name> \
  -v <name>-project:/home/dev/project \
  -p 127.0.0.1:8080:8000 \
  warden4w/gold:latest \
  zsh -l
```

- `-e WARDEN_JAIL_NAME=<name>` — passes the jail's name to the prompt (the gold image only carries the static `WARDEN_JAIL=1` flag). See "Badging the prompt" below.
- `-v <name>-project:/home/dev/project` — project survives `podman rm`; the container is throwaway.
- `-p 127.0.0.1:8080:8000` — host `8080` → container `8000`, loopback only. Services inside the jail must listen on `0.0.0.0`, not the container's own `127.0.0.1`, or the forward won't see them.

### 3. Install dotfiles into the jail

Clone your dotfiles repo inside the jail, then run its installer. (During validation a `podman cp` shortcut was used; the git-clone flow is the intended path.)

```bash
podman exec -it -u dev <name> zsh -lc '
  git clone <dotfiles_git_url> ~/warden-dotfiles &&
  cd ~/warden-dotfiles &&
  ./install.sh
'
```

**Alternative — `podman cp` from a local repo.** If you're iterating on the dotfiles locally (no pushed remote yet, or testing uncommitted changes), copy the repo straight in from your WSL filesystem instead of cloning. `podman cp` lands files as `root`, so fix ownership before running the installer:

```bash
podman cp ~/warden-dotfiles <name>:/home/dev/warden-dotfiles
podman exec -u root <name> chown -R dev:dev /home/dev/warden-dotfiles
podman exec -it -u dev <name> zsh -lc 'cd ~/warden-dotfiles && ./install.sh'
```

`install.sh` symlinks config with backup and is idempotent (`readlink -f` comparison makes re-runs true no-ops), so it's safe to re-run under either flow.

### 4. Connect to the jail

```bash
podman exec -it -u dev <name> zsh -l
```

You should land in the fully configured shell: oh-my-posh prompt, autosuggestions, syntax highlighting. `exit` leaves the jail running.

### 5. Edit project files from the host (optional)

The volume's backing directory and the jail's `/home/dev/project` are the same bytes, so host-side edits and in-jail edits see each other immediately via native inotify.

- **VS Code:** `F1` → **WSL: Connect to WSL** → **File: Open Folder**, then browse to the volume's backing path. (`code <path>` from a plain WSL terminal fails — it resolves to the Windows `Code.exe`.)
- **Resolve the backing path** (don't hardcode it):

```bash
podman volume inspect <name>-project --format '{{.Mountpoint}}'
```

Rootless, this lives under `~/.local/share/containers/storage/volumes/<name>-project/_data`, reachable from Windows via `\\wsl.localhost\<distro>\...`.

### 6. Lifecycle reference

```bash
podman ps                      # running jails
podman ps -a                   # includes stopped jails
podman stop <name>             # stop (files intact)
podman start -ai <name>        # restart and attach
podman rm <name>               # delete the jail (volume survives)
podman volume rm <name>-project   # delete the project data (destructive)
```

`podman rm` never touches mounted volumes — deleting a jail discards only the disposable layer. The project data is gone only when you remove the volume.

---

## Badging the prompt (padlock + jail name)

Goal: the oh-my-posh prompt clearly announces you're inside a jail, and which one — a padlock plus the jail's name, prepended to the normal prompt.

**How the two pieces are wired.** The gold image carries a static `WARDEN_JAIL=1` flag (baked in Part 1); the per-jail name arrives via `-e WARDEN_JAIL_NAME=<name>` at `podman run` (Part 2). The prompt reads both. Gating the badge on `WARDEN_JAIL` means the same config is inert anywhere that variable is absent (e.g. your host), so nothing leaks.

**The tradeoff.** oh-my-posh has no "decorate the built-in default" switch — the moment you add a segment, you're supplying a config file. That nudges against the "no vendored theme" decision, but the smallest correct footprint is a single self-contained theme that *is* the default prompt plus one badge block. It lives in the dotfiles repo, so it's config-in-repo, not baked.

### 1. Export the default theme into the dotfiles repo (once)

```bash
oh-my-posh config export --output ~/warden-dotfiles/oh-my-posh/warden.omp.json
```

This writes out the built-in default as an editable JSON theme.

### 2. Prepend the jail badge block

Open `warden.omp.json` and add this as the **first** entry in the top-level `blocks` array (before the existing block), so the badge renders at the far left of the prompt:

```json
{
  "type": "prompt",
  "alignment": "left",
  "segments": [
    {
      "type": "text",
      "style": "diamond",
      "leading_diamond": "\ue0b6",
      "trailing_diamond": "\ue0b4",
      "foreground": "#ffffff",
      "background": "#c94f4f",
      "template": "{{ if .Env.WARDEN_JAIL }} \uf023 {{ if .Env.WARDEN_JAIL_NAME }}{{ .Env.WARDEN_JAIL_NAME }}{{ else }}JAIL{{ end }} {{ end }}"
    }
  ]
}
```

- `\uf023` is a padlock glyph (Nerd Font — already required by oh-my-posh).
- `{{ if .Env.WARDEN_JAIL }}` — the whole badge renders only when the jail flag is present; inert on the host.
- Falls back to the literal `JAIL` if `WARDEN_JAIL_NAME` wasn't passed, so a jail is always marked even without the per-jail name.

### 3. Point the shell at the theme

In the dotfiles `zsh/zshrc`, initialize oh-my-posh with `--config` pointing at the repo theme instead of the bare default:

```zsh
eval "$(oh-my-posh init zsh --config "$HOME/warden-dotfiles/oh-my-posh/warden.omp.json")"
```

(Use the resolved install path if you clone the dotfiles elsewhere — oh-my-posh wants a full path, not `~`.)

After `install.sh` symlinks the dotfiles, open a fresh login shell (`zsh -l`) and you'll see the red padlock badge with the jail name leading the otherwise-default prompt.

---

## Isolation sanity check

From inside any jail, confirm the host filesystem isn't reachable:

```bash
ls /mnt/c    # expected: No such file or directory
```

A fresh container inherits no `/mnt/c`, and rootless Podman maps in-jail `root` to your unprivileged host UID (1000), so even a breakout lands as an ordinary user. Containment comes from not bind-mounting host paths — the only two-way door is the project volume.
