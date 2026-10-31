"""python3 -m unittest で実行する。ポータルや Discord には接続しない。"""
import json
import os
import tempfile
import unittest
from unittest import mock

import bot


class FakeClient:
    def __init__(self, jobs=None):
        self.jobs = jobs or []
        self.enqueued = 0

    def list_jobs(self, limit=10):
        return self.jobs

    def enqueue(self, target_id):
        self.enqueued += 1
        job = job_of(100 + self.enqueued, 0, 0)
        self.jobs.insert(0, job)
        return job


def job_of(job_id, status, created, score=None):
    job = {1: job_id, 4: status, 5: {1: created}, 18: {1: 1}}
    if score is not None:
        job[9] = score
    return job


class ControllerTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.sent = []
        self.request = os.path.join(self.dir.name, "enqueue.request")
        self.client = FakeClient([job_of(1, 4, 100, 5000)])
        self.controller = self.new_controller()

    def new_controller(self):
        return bot.Controller(
            self.client, notify=lambda c, a=None: self.sent.append(c), code=lambda: "abc",
            state_path=os.path.join(self.dir.name, "state.json"), request_path=self.request,
        )

    def request_bench(self):
        open(self.request, "w").close()

    def test_first_start_does_nothing(self):
        self.controller.tick()
        self.assertEqual(self.client.enqueued, 0)
        self.assertEqual(self.sent, [])

    def test_no_request_does_not_enqueue(self):
        self.controller.tick()
        self.assertEqual(self.client.enqueued, 0)

    def test_request_enqueues_once(self):
        self.request_bench()
        self.controller.tick()
        self.controller.tick()
        self.assertEqual(self.client.enqueued, 1)
        self.assertFalse(os.path.exists(self.request))

    def test_waits_for_running_job_then_enqueues_once(self):
        self.client.jobs.insert(0, job_of(2, 1, 900))
        self.request_bench()
        self.controller.tick()
        self.assertEqual(self.client.enqueued, 0)
        self.client.jobs[0] = job_of(2, 4, 900, 6000)
        self.controller.tick()
        self.assertEqual(self.client.enqueued, 1)

    def test_enqueue_failure_is_retried(self):
        self.request_bench()
        with mock.patch.object(self.client, "enqueue", side_effect=RuntimeError("HTTP 401")):
            with self.assertRaises(RuntimeError):
                self.controller.tick()
        self.assertTrue(os.path.exists(self.request))
        self.controller.tick()
        self.assertEqual(self.client.enqueued, 1)

    def test_finished_job_is_notified_once(self):
        self.client.jobs.insert(0, job_of(2, 4, 900, 7368))
        self.controller.tick()
        self.controller.tick()
        self.assertEqual(len(self.sent), 1)
        self.assertIn("7368", self.sent[0])

    def test_request_survives_restart(self):
        self.request_bench()
        self.new_controller().tick()
        self.assertEqual(self.client.enqueued, 1)


class ReporterTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.log = os.path.join(self.dir.name, "access.json.log")
        self.sent = []
        self.remote_age = 100
        self.remote_lines = 10
        self.remote_ops = []
        self.alp_inputs = []
        patcher = mock.patch.object(bot, "run", side_effect=self.fake_run)
        patcher.start()
        self.addCleanup(patcher.stop)

    def fake_run(self, *args, **kwargs):
        if args[0] == "sudo":
            open(self.log, "w").close()
            return ""
        self.alp_inputs.append(kwargs["input"])
        return "| COUNT |\n|---|\n| 1 |"

    def fake_remote(self, host, operation):
        self.remote_ops.append((host, operation))
        if operation == "status":
            return f"1000 {self.remote_age}"
        if operation == "read":
            return line_of(502) * self.remote_lines
        return ""

    def reporter(self, now, notify=None):
        return bot.Reporter(
            notify=notify or (lambda c, a=None: self.sent.append((c, a))), now=lambda: now, log_path=self.log,
            code=lambda: "abc", remotes={"europe1": "e", "america1": "a"}, remote=self.fake_remote,
        )

    def write(self, count):
        with open(self.log, "w") as f:
            f.write(line_of(200) * count)
        return os.stat(self.log).st_mtime

    def test_does_not_connect_while_asia_has_traffic(self):
        mtime = self.write(100)
        self.reporter(mtime + bot.IDLE_SECONDS - 1).tick()
        self.assertEqual(self.remote_ops, [])
        self.assertEqual(self.sent, [])

    def test_waits_for_remote_idle(self):
        mtime = self.write(100)
        self.remote_age = bot.IDLE_SECONDS - 1
        self.reporter(mtime + bot.IDLE_SECONDS).tick()
        self.assertEqual(self.sent, [])
        self.assertGreater(os.stat(self.log).st_size, 0)

    def test_posts_one_aggregated_message_and_clears_all(self):
        mtime = self.write(100)
        self.reporter(mtime + bot.IDLE_SECONDS).tick()
        self.assertEqual(len(self.sent), 1)
        content, (_, attachment) = self.sent[0]
        self.assertIn("120 リクエスト", content)
        self.assertIn("asia1 100 / europe1 10 / america1 10", content)
        self.assertIn("5xx: 20", content)
        self.assertEqual(len(self.alp_inputs[0].splitlines()), 120)
        for section in ("# 全サーバー", "# asia1", "# europe1", "# america1"):
            self.assertIn(section, attachment)
        self.assertEqual(os.stat(self.log).st_size, 0)
        self.assertIn(("e", "clear"), self.remote_ops)
        self.assertIn(("a", "clear"), self.remote_ops)

    def test_small_traffic_is_cleared_silently(self):
        self.remote_lines = 0
        mtime = self.write(bot.MIN_LOG_LINES - 1)
        self.reporter(mtime + bot.IDLE_SECONDS).tick()
        self.assertEqual(self.sent, [])
        self.assertEqual(os.stat(self.log).st_size, 0)

    def test_post_failure_keeps_all_logs(self):
        mtime = self.write(100)
        with self.assertRaises(RuntimeError):
            self.reporter(mtime + bot.IDLE_SECONDS, notify=mock.Mock(side_effect=RuntimeError("HTTP 500"))).tick()
        self.assertGreater(os.stat(self.log).st_size, 0)
        self.assertNotIn(("e", "clear"), self.remote_ops)

    def test_remote_failure_keeps_all_logs(self):
        mtime = self.write(100)
        with mock.patch.object(self, "fake_remote", side_effect=RuntimeError("ssh failed")), self.assertRaises(RuntimeError):
            self.reporter(mtime + bot.IDLE_SECONDS).tick()
        self.assertEqual(self.sent, [])
        self.assertGreater(os.stat(self.log).st_size, 0)


def line_of(status):
    return json.dumps({"time": "2026-10-31T02:41:00+00:00", "status": status}, separators=(",", ":")) + "\n"


if __name__ == "__main__":
    unittest.main()
