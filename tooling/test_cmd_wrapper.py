#!/usr/bin/env python3
"""Linux regression tests for job cancellation, without Elixir or a database."""

import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time
import unittest


WRAPPER = Path(__file__).resolve().parents[1] / "priv" / "cmd_wrapper.sh"


@unittest.skipUnless(sys.platform.startswith("linux"), "Requires Linux process groups")
class CommandWrapperTest(unittest.TestCase):
    def launch(self, code, *args):
        process = subprocess.Popen(
            ["bash", str(WRAPPER), sys.executable, "-u", "-c", code, *args],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(self.cleanup, process)
        return process

    def cleanup(self, process):
        if process.poll() is None:
            process.stdin.close()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for stream in (process.stdin, process.stdout, process.stderr):
            stream.close()

    def read_ready(self, process):
        line = b""
        while not line.endswith(b"\n"):
            self.assertTrue(select.select([process.stdout], [], [], 5)[0], "Command did not start")
            char = os.read(process.stdout.fileno(), 1)
            self.assertTrue(char, "Command exited before reporting its PID")
            line += char
        pid = int(line)
        self.addCleanup(self.kill_if_running, pid)
        return pid

    @staticmethod
    def running(pid):
        try:
            state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
            return state != "Z"
        except FileNotFoundError:
            return False

    @classmethod
    def kill_if_running(cls, pid):
        if cls.running(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def assert_stopped(self, pid):
        deadline = time.monotonic() + 3
        while self.running(pid) and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertFalse(self.running(pid), f"Process {pid} survived cancellation")

    def tree(self, parent_exits=False):
        # Model a packaged yt-dlp spawning Python, which in turn spawns Deno.
        # Ignore TERM to ensure cancellation forcibly stops the whole group.
        code = """
import os, signal, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
print(os.getpid(), flush=True)
if os.fork() == 0:
    print(os.getpid(), flush=True)
    if os.fork() == 0:
        print(os.getpid(), flush=True)
    while True: time.sleep(1)
"""
        if parent_exits:
            code += "time.sleep(0.2)\n"
        else:
            code += "while True: time.sleep(1)\n"
        process = self.launch(code)
        leader = self.read_ready(process)
        self.read_ready(process)
        descendant = self.read_ready(process)
        return process, leader, descendant

    def test_preserves_output_arguments_and_exit_status(self):
        process = self.launch(
            "import sys; print(repr(sys.argv[1:])); print('error', file=sys.stderr); sys.exit(17)",
            "an argument with spaces", "$(literal)",
        )
        self.assertEqual(process.wait(timeout=5), 17)
        self.assertEqual(process.stdout.read(), "['an argument with spaces', '$(literal)']\n")
        self.assertEqual(process.stderr.read(), "error\n")

    def test_success(self):
        process = self.launch("print('ok')")
        self.assertEqual(process.wait(timeout=5), 0)
        self.assertEqual(process.stdout.read(), "ok\n")

    def test_stdin_closure_kills_descendants(self):
        process, leader, descendant = self.tree()
        process.stdin.close()
        self.assertNotEqual(process.wait(timeout=5), 0)
        self.assert_stopped(leader)
        self.assert_stopped(descendant)

    def test_wrapper_termination_kills_descendants(self):
        process, leader, descendant = self.tree()
        process.terminate()
        self.assertEqual(process.wait(timeout=5), 143)
        self.assert_stopped(leader)
        self.assert_stopped(descendant)

    def test_natural_exit_cleans_up_remaining_descendants(self):
        process, leader, descendant = self.tree(parent_exits=True)
        self.assertEqual(process.wait(timeout=5), 0)
        self.assert_stopped(leader)
        self.assert_stopped(descendant)

    def test_immediate_stdin_closure(self):
        for _ in range(20):
            process = self.launch("import time; time.sleep(60)")
            process.stdin.close()
            self.assertNotEqual(process.wait(timeout=5), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
