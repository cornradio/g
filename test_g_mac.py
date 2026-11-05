import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location("g_mac", Path(__file__).with_name("g.mac.py"))
g_mac = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g_mac)


class RefreshTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.remote = self.root / "remote.git"
        self.repo = self.root / "repo"
        self.other = self.root / "other"
        self.command("init", "--bare", "--initial-branch=main", str(self.remote))
        self.command("clone", str(self.remote), str(self.repo))
        self.configure(self.repo)
        (self.repo / "file.txt").write_text("initial\n")
        self.command("-C", str(self.repo), "add", "-A")
        self.command("-C", str(self.repo), "commit", "-m", "initial")
        self.command("-C", str(self.repo), "push", "-u", "origin", "main")
        self.command("clone", str(self.remote), str(self.other))
        self.configure(self.other)
        self.browser = object.__new__(g_mac.Browser)
        self.browser.screen = Mock()
        self.browser.current_path = str(self.root)
        self.browser.ignore_file = self.root / "ignore.json"
        self.browser.ignored = set()
        self.browser.find = "repo"
        self.browser.dirty_only = False
        self.browser.selected = 0
        self.browser.pending_name = ""
        self.browser.rows = g_mac.list_directory(self.root)
        self.browser.here = g_mac.current_repo(self.root)
        self.browser.message = Mock()

    def command(self, *args):
        return subprocess.run(
            ["git", *args], check=True, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    def configure(self, repo):
        self.command("-C", str(repo), "config", "user.name", "Refresh Test")
        self.command("-C", str(repo), "config", "user.email", "test@example.invalid")
        self.command("-C", str(repo), "config", "commit.gpgsign", "false")

    def selected(self):
        return self.browser.selected_row(self.browser.shown_rows())

    def test_pull_refreshes_tracking_and_new_files(self):
        (self.other / "new.txt").write_text("remote change\n")
        self.command("-C", str(self.other), "add", "-A")
        self.command("-C", str(self.other), "commit", "-m", "remote change")
        self.command("-C", str(self.other), "push")
        self.command("-C", str(self.repo), "fetch")
        self.browser.reload_directory()
        self.assertEqual(self.selected()["behind"], 1)
        self.browser.run_git_action("pull", self.selected())
        self.assertEqual(self.selected()["behind"], 0)
        self.assertTrue((self.repo / "new.txt").exists())
        self.assertEqual(self.browser.find, "repo")
        self.browser.screen.clearok.assert_called_with(True)

    def test_commit_and_push_refresh_dirty_and_ahead_counts(self):
        (self.repo / "file.txt").write_text("local change\n")
        self.browser.reload_directory()
        self.assertEqual(self.selected()["dirty"], 1)
        self.browser.run_git_action("commit", self.selected())
        self.assertEqual(self.selected()["dirty"], 0)
        self.assertEqual(self.selected()["ahead"], 1)
        self.browser.run_git_action("push", self.selected())
        self.assertEqual(self.selected()["ahead"], 0)

    def test_refresh_after_failed_pull(self):
        (self.repo / "file.txt").write_text("uncommitted local change\n")
        (self.other / "file.txt").write_text("conflicting remote change\n")
        self.command("-C", str(self.other), "add", "-A")
        self.command("-C", str(self.other), "commit", "-m", "remote change")
        self.command("-C", str(self.other), "push")
        self.browser.run_git_action("pull", self.selected())
        self.assertEqual(self.selected()["dirty"], 1)
        self.assertEqual(self.selected()["behind"], 1)
        self.assertTrue(self.browser.message.called)

    def test_manual_refresh_preserves_filters_and_reads_ignore_file(self):
        (self.repo / "file.txt").write_text("external change\n")
        self.browser.dirty_only = True
        self.browser.ignore_file.write_text('{"paths":[]}')
        self.browser.ignored = {str(self.repo)}
        self.browser.screen.get_wch.side_effect = ["r", "q"]
        self.browser.draw = Mock(return_value=([], None))
        self.assertEqual(self.browser.run(), str(self.root))
        self.assertEqual(self.selected()["dirty"], 1)
        self.assertEqual(self.browser.find, "repo")
        self.assertTrue(self.browser.dirty_only)
        self.assertEqual(self.browser.ignored, set())
        self.browser.screen.clearok.assert_called_with(True)

    def test_resume_forces_terminal_repaint(self):
        with patch.object(g_mac.curses, "reset_prog_mode"), \
                patch.object(g_mac.curses, "noecho"), \
                patch.object(g_mac.curses, "cbreak"), \
                patch.object(g_mac.curses, "curs_set"):
            self.browser.resume()
        self.browser.screen.clearok.assert_called_once_with(True)


if __name__ == "__main__":
    unittest.main()
