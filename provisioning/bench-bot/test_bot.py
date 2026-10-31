"""python3 -m unittest で実行する。ポータルや Discord には接続しない。"""
import contextlib
import io
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
        # 実際の API と同じく、一覧には合否とログ (18) を含めない。
        return [{k: v for k, v in j.items() if k != 18} for j in self.jobs]

    def get_job(self, job_id):
        return next(j for j in self.jobs if j.get(1) == job_id)

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


class DeployedCodeTest(unittest.TestCase):
    def fake_run(self, dirty):
        return lambda *args, **kwargs: dirty if "status" in args else "abc subject"

    def test_clean(self):
        with mock.patch.object(bot, "run", side_effect=self.fake_run("")):
            self.assertEqual(bot.deployed_code(), "abc subject")

    def test_counts_tracked_changes(self):
        with mock.patch.object(bot, "run", side_effect=self.fake_run(" M a.go\n M b.go")):
            self.assertEqual(bot.deployed_code(), "abc subject (未コミットの変更 2 件)")

    def test_ignores_untracked_files(self):
        with mock.patch.object(bot, "run", side_effect=self.fake_run("")) as run:
            bot.deployed_code()
        self.assertTrue(any("--untracked-files=no" in call.args for call in run.call_args_list))


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
            results_dir=os.path.join(self.dir.name, "results"),
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
        self.assertIn("✅", self.sent[0])

    def test_finished_job_writes_result(self):
        job = job_of(2, 4, 900, 7368)
        job[18][5] = {2: "bench log"}
        self.client.jobs.insert(0, job)
        self.controller.tick()
        result = bot.read_job_result(self.controller.results_dir, 2)
        self.assertEqual((result["score"], result["passed"], result["log"]), (7368, True, "bench log"))

    def test_latest_job_is_written_before_request_is_removed(self):
        self.request_bench()
        seen = []
        real_remove = os.remove
        with mock.patch.object(bot.os, "remove", side_effect=lambda p: (seen.append(bot.read_latest_job(self.controller.results_dir)), real_remove(p))):
            self.controller.tick()
        self.assertEqual(seen, [101])

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
            results_dir=os.path.join(self.dir.name, "results"),
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

    def test_alp_is_saved_for_latest_job(self):
        results = os.path.join(self.dir.name, "results")
        bot.write_latest_job(results, 7)
        mtime = self.write(100)
        self.reporter(mtime + bot.IDLE_SECONDS).tick()
        with open(os.path.join(results, "7", "alp.md"), encoding="utf-8") as f:
            self.assertIn("# 全サーバー", f.read())

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


class CommandTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.results = os.path.join(self.dir.name, "results")
        self.request = os.path.join(self.dir.name, "enqueue.request")
        self.clock = 0
        self.steps = []

    def now(self):
        return self.clock

    def sleep(self, seconds):
        self.clock += seconds
        if self.steps:
            self.steps.pop(0)()

    def enqueue(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = bot.command_enqueue(self.results, self.request, self.sleep, self.now)
        return code, out.getvalue()

    def job_done(self, passed=True, status="FINISHED"):
        bot.write_result(self.results, 7, "job.json", json.dumps(
            {"job": 7, "status": status, "passed": passed, "score": 1234, "code": "abc", "log": "bench log"}))

    def accept(self):
        bot.write_latest_job(self.results, 7)
        os.remove(self.request)

    def test_prints_score_and_log_without_waiting_for_alp(self):
        self.steps = [self.accept, self.job_done]
        code, out = self.enqueue()
        self.assertEqual(code, 0)
        for text in ("score=1234", "bench log"):
            self.assertIn(text, out)
        self.assertNotIn("--- alp ---", out)
        self.assertEqual(self.clock, 2 * bot.POLL_SECONDS)

    def test_failed_job_exits_non_zero(self):
        self.steps = [self.accept, lambda: self.job_done(passed=False, status="ERRORED")]
        code, out = self.enqueue()
        self.assertEqual(code, 1)

    def test_bot_not_consuming_request_times_out(self):
        code, out = self.enqueue()
        self.assertEqual(code, 2)
        self.assertIn("投入できませんでした", out)

    def test_refuses_after_contest(self):
        self.clock = bot.CONTEST_END
        self.assertEqual(self.enqueue()[0], 2)
        self.assertFalse(os.path.exists(self.request))

    def test_result_prints_saved_alp(self):
        self.job_done()
        bot.write_result(self.results, 7, "alp.md", "ALP TABLE")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(bot.command_result(7, self.results), 0)
        for text in ("score=1234", "bench log", "ALP TABLE"):
            self.assertIn(text, out.getvalue())

    def test_result_of_unknown_job(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(bot.command_result(99, self.results), 2)


def line_of(status):
    return json.dumps({"time": "2026-10-31T02:41:00+00:00", "status": status}, separators=(",", ":")) + "\n"


if __name__ == "__main__":
    unittest.main()
