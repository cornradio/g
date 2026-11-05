#!/usr/bin/env python3
import codecs
import curses
import json
import locale
import os
import re
import shlex
import shutil
import subprocess
import sys
import unicodedata
from pathlib import Path


PAGE_SIZE = 15
DEFAULT_MESSAGE = "update"


def git(path, *args, non_interactive=False, stream=False):
    env = None
    options = []
    if non_interactive:
        env = os.environ.copy()
        env.update(
            GIT_TERMINAL_PROMPT="0",
            GIT_ASKPASS="/usr/bin/false",
            SSH_ASKPASS="/usr/bin/false",
            GCM_INTERACTIVE="never",
        )
        options = ["-c", "credential.interactive=false"]
    command = ["git", "-C", str(path), *options, *args]
    if stream:
        output = []
        decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        with subprocess.Popen(
            command,
            env=env,
            stdin=subprocess.DEVNULL if non_interactive else None,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        ) as process:
            while True:
                chunk = os.read(process.stdout.fileno(), 4096)
                if not chunk:
                    break
                text = decoder.decode(chunk)
                output.append(text)
                print(text, end="", flush=True)
            tail = decoder.decode(b"", final=True)
            output.append(tail)
            print(tail, end="", flush=True)
            return subprocess.CompletedProcess(command, process.wait(), "".join(output), "")
    return subprocess.run(
        command,
        env=env,
        stdin=subprocess.DEVNULL if non_interactive else None,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def authentication_help(path, output):
    markers = (
        "could not read username", "could not read password",
        "unable to get password from user", "unable to get username from user",
        "terminal prompts disabled", "authentication failed",
        "authentication required", "invalid username or",
        "invalid credentials", "permission denied (publickey",
        "could not read from remote repository",
        "requested url returned error: 401", "requested url returned error: 403",
    )
    if not any(marker in output.casefold() for marker in markers):
        return ""
    return (
        "\n\n  Authentication failed. g does not ask for a username or password.\n"
        "  Existing credential helpers are still used; no login settings were changed.\n"
        "  Exit g and run these commands in your terminal:\n\n"
        f"    cd -- {shlex.quote(str(path))}\n"
        "    git remote -v\n"
        "    git config --show-origin --get-all credential.helper\n\n"
        "  GitHub HTTPS + GitHub CLI (gh): reuse your existing login first:\n\n"
        "    gh auth status\n"
        "    gh auth setup-git\n\n"
        "  Only if gh reports that you are not logged in:\n\n"
        "    gh auth login --hostname github.com --git-protocol https --web\n"
        "    gh auth setup-git\n\n"
        "  Without gh, you can use the macOS Keychain helper:\n\n"
        "    git config --global credential.helper osxkeychain\n"
        "    git pull\n\n"
        "  That one-time manual pull may ask for your GitHub username and a personal\n"
        "  access token (NOT your account password), then save it in Keychain.\n"
        "  If remote -v shows an SSH URL, HTTPS credentials do not apply;\n"
        "  configure your SSH key instead. Also check access to the repository.\n"
        "  Never paste your token into chat or put it in the remote URL.\n"
    )


def norm(path):
    return os.path.normcase(os.path.abspath(path)).rstrip(os.sep)


def repo_status(path):
    result = git(path, "status", "--porcelain=v1", "--branch", "--untracked-files=normal")
    if result.returncode:
        return None

    lines = result.stdout.splitlines()
    if not lines or not lines[0].startswith("## "):
        return None

    head = lines[0][3:]
    branch_part, _, tracking = head.partition(" [")
    branch, separator, upstream = branch_part.partition("...")
    if branch.startswith("No commits yet on "):
        branch = branch.removeprefix("No commits yet on ")
    detached = branch == "HEAD (no branch)" or branch.startswith("HEAD ")

    ahead_match = re.search(r"\bahead (\d+)", tracking)
    behind_match = re.search(r"\bbehind (\d+)", tracking)
    info = {
        "branch": branch,
        "upstream": upstream if separator else "",
        "ahead": int(ahead_match.group(1)) if ahead_match else 0,
        "behind": int(behind_match.group(1)) if behind_match else 0,
        "dirty": len(lines) - 1,
        "detached": detached,
    }

    if detached:
        refs = git(
            path, "for-each-ref", "--points-at", "HEAD", "refs/heads",
            "--format=%(refname:short)|%(upstream:short)",
        ).stdout.splitlines()
        candidates = []
        for ref in refs:
            name, _, ref_upstream = ref.partition("|")
            if name:
                candidates.append((name, ref_upstream))
        pick = next((item for item in candidates if item[0] in ("main", "master")), None)
        if pick is None and len(candidates) == 1:
            pick = candidates[0]
        if pick is None:
            pick = next((item for item in candidates if item[1]), None)
        if pick is None and candidates:
            pick = candidates[0]
        if pick:
            info.update(branch=pick[0], upstream=pick[1], ahead=0, behind=0)
            if pick[1]:
                counts = git(path, "rev-list", "--left-right", "--count", f"{pick[1]}...HEAD")
                values = counts.stdout.split()
                if len(values) == 2 and all(value.isdigit() for value in values):
                    info["behind"], info["ahead"] = map(int, values)

    return info


def make_row(path, name=None):
    path = os.path.abspath(path)
    is_dir = os.path.isdir(path)
    is_repo = is_dir and os.path.exists(os.path.join(path, ".git"))
    info = repo_status(path) if is_repo else None
    row = {
        "name": name if name is not None else os.path.basename(path),
        "path": path,
        "is_dir": is_dir,
        "is_repo": is_repo,
    }
    if info:
        row.update(info)
    else:
        row.update(branch="", upstream="", ahead=0, behind=0, dirty=0, detached=False)
    return row


def current_repo(path):
    result = git(path, "rev-parse", "--show-toplevel")
    if result.returncode == 0:
        return make_row(result.stdout.strip())
    return make_row(path)


def list_directory(path):
    rows = []
    with os.scandir(path) as entries:
        for entry in entries:
            if entry.name.startswith("."):
                continue
            try:
                rows.append(make_row(entry.path, entry.name))
            except OSError:
                continue
    return sorted(rows, key=lambda row: (
        0 if row["is_repo"] else 1 if row["is_dir"] else 2,
        row["name"].casefold(),
    ))


def text_width(text):
    width = 0
    for char in text:
        if char == "\t":
            width += 8 - width % 8
        else:
            width += 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
    return width


def fit(text, width):
    if width <= 0:
        return ""
    result = ""
    used = 0
    for char in text:
        char_width = 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
        if used + char_width > width:
            break
        result += char
        used += char_width
    return result + " " * (width - used)


def ignored_paths(ignore_file):
    if not ignore_file.exists():
        return set()
    with ignore_file.open(encoding="utf-8") as file:
        data = json.load(file)
    return {norm(path) for path in data.get("paths", []) if isinstance(path, str)}


class Browser:
    def __init__(self, screen):
        self.screen = screen
        self.current_path = os.getcwd()
        self.ignore_file = Path(self.current_path) / "ignore.json"
        self.ignored = ignored_paths(self.ignore_file)
        self.selected = 0
        self.dirty_only = False
        self.find = ""
        self.rows = []
        self.here = None
        self.list_path = None
        self.pending_name = ""
        self.load_directory()
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_CYAN, -1)
        curses.init_pair(2, curses.COLOR_GREEN, -1)
        curses.init_pair(3, curses.COLOR_YELLOW, -1)
        curses.init_pair(4, curses.COLOR_RED, -1)
        curses.init_pair(5, curses.COLOR_WHITE, -1)
        curses.init_pair(6, curses.COLOR_BLACK, curses.COLOR_YELLOW)
        curses.curs_set(0)

    def load_directory(self):
        previous = self.pending_name
        self.rows = list_directory(self.current_path)
        self.here = current_repo(self.current_path)
        self.list_path = self.current_path
        self.find = ""
        self.selected = 0
        if previous:
            self.selected = next(
                (index for index, row in enumerate(self.rows) if row["name"] == previous),
                0,
            )
        self.pending_name = ""

    def reload_directory(self):
        selected = self.selected_row(self.shown_rows())
        selected_path = selected["path"] if selected else ""
        self.rows = list_directory(self.current_path)
        self.here = current_repo(self.current_path)
        self.list_path = self.current_path
        self.selected = next(
            (index for index, row in enumerate(self.shown_rows()) if row["path"] == selected_path),
            0,
        )

    def is_ignored(self, row):
        return norm(row["path"]) in self.ignored

    def dirty(self, row):
        return row["is_repo"] and not self.is_ignored(row) and (
            row["dirty"] > 0 or row["ahead"] > 0 or row["behind"] > 0
        )

    def shown_rows(self):
        return [
            row for row in self.rows
            if (not self.find or self.find.casefold() in row["name"].casefold())
            and (not self.dirty_only or self.dirty(row))
        ]

    def selected_row(self, shown):
        return shown[self.selected] if shown and 0 <= self.selected < len(shown) else None

    def target(self, selected):
        if selected and selected["is_repo"]:
            return selected
        return self.here

    def write(self, y, x, value, color=0, width=None):
        height, screen_width = self.screen.getmaxyx()
        if not (0 <= y < height) or x >= screen_width:
            return
        if width is None:
            width = screen_width - x
        value = fit(value, min(width, screen_width - x))
        try:
            self.screen.addstr(y, x, value, color)
        except curses.error:
            pass

    def draw(self):
        screen = self.screen
        screen.erase()
        height, width = screen.getmaxyx()
        shown = self.shown_rows()
        if shown:
            self.selected = max(0, min(self.selected, len(shown) - 1))
        else:
            self.selected = 0
        page = self.selected // PAGE_SIZE
        pages = max(1, (len(shown) + PAGE_SIZE - 1) // PAGE_SIZE)
        start = page * PAGE_SIZE
        selected = self.selected_row(shown)
        target = self.target(selected)

        identity_path = target["path"] if target else None
        name = git(identity_path, "config", "--get", "user.name").stdout.strip() if identity_path else ""
        email = git(identity_path, "config", "--get", "user.email").stdout.strip() if identity_path else ""
        if not name:
            name = subprocess.run(
                ["git", "config", "--global", "--get", "user.name"],
                text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            ).stdout.strip()
        if not email:
            email = subprocess.run(
                ["git", "config", "--global", "--get", "user.email"],
                text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            ).stdout.strip()

        identity_color = curses.color_pair(1) if name and email else curses.color_pair(4)
        self.write(0, 0, f"  {name or '?'} <{email or 'no email'}>", identity_color)
        if self.here and self.here["is_repo"]:
            tag = "clean" if self.here["dirty"] == 0 or self.is_ignored(self.here) else str(self.here["dirty"])
            prefix = "* " if self.is_ignored(self.here) else ""
            status = f"  {prefix}{self.here['name']} · {self.here['branch']} · {tag}"
            if not self.is_ignored(self.here):
                if self.here["ahead"]:
                    status += f" +{self.here['ahead']}"
                if self.here["behind"]:
                    status += f" -{self.here['behind']}"
            status_color = curses.color_pair(
                2 if self.here["dirty"] == 0 or self.is_ignored(self.here) else 3
            )
        else:
            status = f"  {self.current_path}"
            status_color = curses.color_pair(1)
        if self.find:
            status += f"  /{self.find}"
        self.write(1, 0, status, status_color)
        self.write(2, 0, "─" * max(1, width), curses.color_pair(5))

        if not shown:
            empty = "<no match>" if self.find else "<no dirty>" if self.dirty_only else "<Empty>"
            self.write(3, 0, f"  {empty}", curses.color_pair(5))
        else:
            for offset, row in enumerate(shown[start:start + PAGE_SIZE]):
                mark = "* " if row["is_dir"] and self.is_ignored(row) else "  "
                label = row["name"] + ("/" if row["is_dir"] and not row["is_repo"] else "")
                line = f"  {mark}{label}"
                color = curses.color_pair(5)
                if row["is_repo"]:
                    branch = row["branch"]
                    line += " " * max(1, 30 - text_width(line)) + branch
                    line += " " * max(1, 50 - text_width(line))
                    line += "clean" if row["dirty"] == 0 or self.is_ignored(row) else str(row["dirty"])
                    if not self.is_ignored(row):
                        if row["ahead"]:
                            line += f"  +{row['ahead']}"
                        if row["behind"]:
                            line += f"  -{row['behind']}"
                    color = curses.color_pair(
                        2 if row["dirty"] == 0 or self.is_ignored(row) else 3
                    )
                elif row["is_dir"]:
                    color = curses.color_pair(1)
                if start + offset == self.selected:
                    color = curses.color_pair(6)
                self.write(3 + offset, 0, line, color)

        footer = max(4 + PAGE_SIZE, height - 3)
        self.write(footer, 0, "─" * max(1, width), curses.color_pair(5))
        tag = f" {page + 1}/{pages}" + ("  dirty" if self.dirty_only else "")
        self.write(footer + 1, 0, f"{tag}  [R] Refresh  [Y] Dirty  [/] Find  [C] Commit  [Shift+C] Edit", curses.color_pair(2))
        self.write(footer + 2, 0, " [L] Pull  [P] Push  [I] Ignore  [D] Trash  [G] Desktop  [V] Code  [Q] Quit", curses.color_pair(2))
        screen.refresh()
        return shown, selected

    def suspend(self):
        self.screen.clear()
        self.screen.refresh()
        curses.endwin()

    def resume(self):
        curses.reset_prog_mode()
        curses.noecho()
        curses.cbreak()
        curses.curs_set(0)
        self.screen.clear()
        self.screen.clearok(True)
        self.screen.refresh()

    def message(self, title, command=None, path=None, output=None):
        self.suspend()
        print(f"  {title}", flush=True)
        if command:
            result = subprocess.run(command, cwd=path, text=True, encoding="utf-8", errors="replace")
            if result.returncode:
                print(f"\n  Command exited with status {result.returncode}.", flush=True)
        if output:
            print(output, end="" if output.endswith("\n") else "\n", flush=True)
        input("\n  Press Enter to return...")
        self.resume()

    def prompt(self, label, initial=""):
        curses.curs_set(1)
        y = self.screen.getmaxyx()[0] - 1
        width = self.screen.getmaxyx()[1]
        value = initial
        while True:
            self.screen.move(y, 0)
            self.screen.clrtoeol()
            self.write(y, 0, label + value, width=width)
            self.screen.move(y, min(text_width(label + value), max(0, width - 1)))
            self.screen.refresh()
            key = self.screen.get_wch()
            if key in ("\n", "\r", curses.KEY_ENTER):
                curses.curs_set(0)
                return value
            if key in ("\x1b",):
                curses.curs_set(0)
                return None
            if key in (curses.KEY_BACKSPACE, "\x7f", "\b"):
                value = value[:-1]
            elif isinstance(key, str) and key.isprintable():
                value += key

    def run_git_action(self, action, row):
        try:
            self.perform_git_action(action, row)
        finally:
            self.reload_directory()
            self.screen.clearok(True)

    def perform_git_action(self, action, row):
        if not row:
            self.message("Not a git repository.")
            return
        path = row["path"]
        if action in ("pull", "push") and (not row["branch"] or row["branch"].startswith("HEAD ")):
            self.message(f"{os.path.basename(path)} has no branch to {action}.")
            return
        if row["detached"] and action in ("pull", "push"):
            result = git(path, "switch", "--", row["branch"])
            if result.returncode:
                self.message(result.stderr.strip() or "Could not switch to the branch.")
                return

        remotes = git(path, "remote").stdout.split()
        remote = "origin" if "origin" in remotes else remotes[0] if remotes else ""
        if action == "commit":
            message = DEFAULT_MESSAGE
            result = git(path, "add", "-A")
            if result.returncode == 0:
                result = git(path, "commit", "-m", message)
            self.message(
                f"{os.path.basename(path)} · {row['branch']}",
                output=result.stdout + result.stderr,
            )
        elif action == "edit_commit":
            message = self.prompt(" message: ", DEFAULT_MESSAGE)
            if message is None or not message.strip():
                return
            message = message.strip()
            add = git(path, "add", "-A")
            result = git(path, "commit", "-m", message) if add.returncode == 0 else add
            output = (add.stdout + add.stderr if add.returncode else "") + result.stdout + result.stderr
            self.message(f"{os.path.basename(path)} · {row['branch']}", output=output)
        elif action in ("pull", "push"):
            if row["upstream"]:
                args = ["pull"] if action == "pull" else ["push"]
            elif not remote:
                self.message("No git remote.")
                return
            elif action == "pull":
                args = ["pull", remote, row["branch"]]
            else:
                args = ["push", "-u", remote, row["branch"]]
            direction = f"{row['upstream']} -> {row['branch']}" if action == "pull" and row["upstream"] else (
                f"{row['branch']} -> {row['upstream']}" if row["upstream"] else f"{remote}/{row['branch']}"
            )
            args.insert(1, "--progress")
            self.suspend()
            try:
                print(f"  {action.title()} {direction}\n  Running...\n", flush=True)
                result = git(path, *args, non_interactive=True, stream=True)
                if result.returncode:
                    print(f"\n  Git exited with status {result.returncode}.", flush=True)
                    guide = authentication_help(path, result.stdout)
                    if guide:
                        print(guide, flush=True)
                else:
                    print("\n  Done.", flush=True)
                input("\n  Press Enter to return...")
            finally:
                self.resume()

    def show_status(self, row):
        if not row:
            self.message("Not a git repository.")
            return
        path = row["path"]
        while True:
            result = git(path, "-c", "color.ui=always", "--no-pager", "status")
            self.suspend()
            print(f"  {os.path.basename(path)}\n", flush=True)
            print(result.stdout + result.stderr, end="", flush=True)
            answer = input("\n  [R] Discard all changes    [Enter] Return\n  > ").strip()
            if answer.casefold() != "r":
                self.resume()
                break
            confirm = input(f"  Discard all changes in {os.path.basename(path)}? (y/N) ")
            if confirm.casefold() == "y":
                reset = git(path, "reset", "--hard")
                print(reset.stdout + reset.stderr, end="", flush=True)
                if reset.returncode == 0:
                    clean = git(path, "clean", "-fd")
                    print(clean.stdout + clean.stderr, end="", flush=True)
                input("\n  Press Enter to continue...")
            self.resume()
        self.reload_directory()

    def delete_selected(self, row, skip_confirm):
        if not row:
            return
        if not skip_confirm:
            answer = self.prompt(f" Move [{row['name']}] to Trash? (Y/n) ")
            if answer is None:
                return
            answer = answer.strip()
            if answer and answer.casefold() != "y":
                return
        result = subprocess.run(
            [
                "osascript",
                "-e", "on run argv",
                "-e", 'tell application "Finder" to delete POSIX file (item 1 of argv)',
                "-e", "end run",
                row["path"],
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if result.returncode:
            self.message("Move to Trash failed:\n" + result.stderr.strip())
        else:
            self.reload_directory()

    def open_app(self, app, path):
        try:
            if app == "code" and shutil.which("code"):
                subprocess.Popen(["code", path])
            else:
                app_name = "GitHub Desktop" if app == "github" else "Visual Studio Code"
                subprocess.Popen(["open", "-a", app_name, path])
        except OSError as error:
            self.message(f"{app} could not be opened: {error}")

    def toggle_ignore(self, row):
        if not row:
            return
        key = norm(row["path"])
        if key in self.ignored:
            self.ignored.remove(key)
        else:
            self.ignored.add(key)
        with self.ignore_file.open("w", encoding="utf-8") as file:
            json.dump({"paths": sorted(self.ignored)}, file, ensure_ascii=False, separators=(",", ":"))

    def run(self):
        while True:
            shown, selected = self.draw()
            key = self.screen.get_wch()
            if key == "\x1b" and self.find:
                self.find = ""
                self.selected = 0
                continue
            if key in ("q", "Q", "\x1b"):
                return self.current_path
            if key in (curses.KEY_UP, "k", "K"):
                self.selected = (self.selected - 1) % len(shown) if shown else 0
            elif key in (curses.KEY_DOWN, "j", "J"):
                self.selected = (self.selected + 1) % len(shown) if shown else 0
            elif key in (curses.KEY_LEFT, curses.KEY_BACKSPACE, "\x7f", "h", "H"):
                parent = os.path.dirname(self.current_path.rstrip(os.sep))
                if parent and parent != self.current_path:
                    self.pending_name = os.path.basename(self.current_path)
                    self.current_path = parent
                    self.load_directory()
            elif key in (curses.KEY_RIGHT, "\n", "\r"):
                if selected:
                    if selected["is_dir"] and not selected["is_repo"]:
                        self.current_path = selected["path"]
                        self.load_directory()
                    elif selected["is_repo"] and key == curses.KEY_RIGHT:
                        self.current_path = selected["path"]
                        self.load_directory()
                    elif selected["is_repo"]:
                        self.show_status(self.target(selected))
            elif key in ("y", "Y"):
                keep = selected["path"] if selected else ""
                self.dirty_only = not self.dirty_only
                filtered = self.shown_rows()
                self.selected = next((i for i, row in enumerate(filtered) if row["path"] == keep), 0)
            elif key in ("r", "R"):
                self.ignored = ignored_paths(self.ignore_file)
                self.reload_directory()
                self.screen.clearok(True)
            elif key == "/":
                keep = selected["path"] if selected else ""
                new_find = self.prompt("  Search (empty clears): ")
                if new_find is not None:
                    self.find = new_find.strip()
                filtered = self.shown_rows()
                self.selected = next((i for i, row in enumerate(filtered) if row["path"] == keep), 0)
            elif key in (",", "<"):
                self.selected = max(0, (self.selected // PAGE_SIZE - 1) * PAGE_SIZE)
            elif key in (".", ">"):
                self.selected = min(max(0, len(shown) - 1), (self.selected // PAGE_SIZE + 1) * PAGE_SIZE)
            elif key in ("g", "G"):
                open_path = selected["path"] if selected and selected["is_dir"] else (
                    os.path.dirname(selected["path"]) if selected else self.current_path
                )
                self.open_app("github", open_path)
            elif key in ("v", "V"):
                self.open_app("code", selected["path"] if selected else self.current_path)
            elif key in ("d", "D") and selected:
                self.delete_selected(selected, key == "D")
            elif key in ("i", "I"):
                target = selected if selected and selected["is_dir"] else self.target(selected)
                self.toggle_ignore(target)
            elif key in ("c", "C"):
                self.run_git_action("edit_commit" if key == "C" else "commit", self.target(selected))
            elif key in ("l", "L"):
                self.run_git_action("pull", self.target(selected))
            elif key in ("p", "P"):
                self.run_git_action("push", self.target(selected))


def main():
    if not shutil.which("git"):
        print("g: git not found in PATH", file=sys.stderr)
        return 1
    if len(sys.argv) != 2:
        print("g: expected a destination file from the shell wrapper", file=sys.stderr)
        return 2
    locale.setlocale(locale.LC_ALL, "")
    try:
        destination = curses.wrapper(lambda screen: Browser(screen).run())
    except (OSError, curses.error, json.JSONDecodeError) as error:
        print(f"g: {error}", file=sys.stderr)
        return 1
    with open(sys.argv[1], "w", encoding="utf-8") as file:
        file.write(destination + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
