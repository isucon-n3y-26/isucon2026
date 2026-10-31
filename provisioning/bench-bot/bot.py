#!/usr/bin/env python3
"""enqueue.sh の要求を受けてベンチを投入し、スコアと alp を Discord に通知する常駐プロセス。

各自の手元から rsync でデプロイされても消えないよう、/home/isucon/bench-bot/ に置いて動かす。
asia1 で動かし、他のサーバーのログはルーターを経由する private IP で集める。
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

TARGET_ID = int(os.environ.get("BOT_TARGET_ID", "65"))
STATE_PATH = os.environ.get("BOT_STATE_PATH", "/home/isucon/bench-bot/state.json")
RESULTS_DIR = os.environ.get("BOT_RESULTS_DIR", "/home/isucon/bench-bot/results")
REQUEST_PATH = os.environ.get("BOT_REQUEST_PATH", "/home/isucon/bench-bot/enqueue.request")
ACCESS_LOG = os.environ.get("BOT_ACCESS_LOG", "/var/log/nginx/access.json.log")
REPO_DIR = "/home/isucon/isucon2026"
SSH_KEY = "/home/isucon/bench-bot/ssh_key"
# public IP はルーターを迂回するので使わない。
REMOTES = {"europe1": "192.168.2.10", "america1": "192.168.3.10"}
POLL_SECONDS = 5
JOB_WAIT_SECONDS = 900
CONTEST_END = 1793437200  # 2026-10-31 18:00 JST
# SSE は nginx のタイムアウト (60秒) で切れてからログに出るので、それより長く待つ。
IDLE_SECONDS = 75
# ヘルスチェックなどの少量のアクセスは走行として通知しない。
MIN_LOG_LINES = 30
MATCHING = (
    "/api/images/.+,/api/posts/[^/]+/comments,/api/posts/[^/]+/realmojis,/api/posts/[^/]+,/api/users/.+,"
    "/api/memories/.+,/api/comments/.+,/api/realmojis/.+,/api/friend-requests/.+,/api/friendships/.+,"
    "/api/follows/.+,/api/blocks/.+,/api/admin/users/.+"
)
JOB_ACTIVE = (0, 1)  # PENDING, RUNNING
JOB_STATUS = {0: "PENDING", 1: "RUNNING", 2: "ERRORED", 3: "CANCELLED", 4: "FINISHED"}


def send_discord(content, attachment=None):
    """attachment は (ファイル名, 本文) のタプル。"""
    payload = json.dumps({"content": content[:2000], "allowed_mentions": {"parse": []}})
    boundary = uuid.uuid4().hex
    body = f'--{boundary}\r\nContent-Disposition: form-data; name="payload_json"\r\nContent-Type: application/json\r\n\r\n{payload}\r\n'
    if attachment:
        name, text = attachment
        body += f'--{boundary}\r\nContent-Disposition: form-data; name="files[0]"; filename="{name}"\r\nContent-Type: text/plain\r\n\r\n{text}\r\n'
    body += f"--{boundary}--\r\n"
    request = urllib.request.Request(
        os.environ["DISCORD_WEBHOOK_URL"],
        data=body.encode(),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}", "User-Agent": "isucon-bench-bot/1.0"},
    )
    try:
        with urllib.request.urlopen(request, timeout=15):
            return
    except urllib.error.HTTPError as e:
        # 例外の文字列に Webhook URL を含めない。
        raise RuntimeError(f"Discord への送信に失敗 (HTTP {e.code})") from None
    except urllib.error.URLError as e:
        raise RuntimeError(f"Discord への送信に失敗 ({e.reason})") from None


def write_result(results_dir, job_id, name, text):
    directory = os.path.join(results_dir, str(job_id))
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, name + ".tmp"), "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(os.path.join(directory, name + ".tmp"), os.path.join(directory, name))


def write_latest_job(results_dir, job_id):
    os.makedirs(results_dir, exist_ok=True)
    with open(os.path.join(results_dir, "latest_job.tmp"), "w", encoding="utf-8") as f:
        f.write(str(job_id))
    os.replace(os.path.join(results_dir, "latest_job.tmp"), os.path.join(results_dir, "latest_job"))


def read_latest_job(results_dir):
    try:
        with open(os.path.join(results_dir, "latest_job"), encoding="utf-8") as f:
            return int(f.read())
    except (FileNotFoundError, ValueError):
        return None


def run(*args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, timeout=60, check=True, **kwargs).stdout.strip()


def deployed_code():
    try:
        commit = run("git", "-C", REPO_DIR, "log", "-1", "--format=%h %s")
        # rsync は古いファイルを消さないので、未追跡のファイルは数えない。
        dirty = run("git", "-C", REPO_DIR, "status", "--porcelain", "--untracked-files=no", "--", "webapp", "provisioning")
        return commit + (f" (未コミットの変更 {len(dirty.splitlines())} 件)" if dirty else "")
    except (subprocess.SubprocessError, OSError):
        return "不明"


class Controller:
    def __init__(self, client, notify=send_discord, code=deployed_code, state_path=STATE_PATH, request_path=REQUEST_PATH, results_dir=RESULTS_DIR):
        self.client, self.notify, self.code, self.results_dir = client, notify, code, results_dir
        self.state_path, self.request_path = state_path, request_path
        self.state = self._load()

    def _load(self):
        try:
            with open(self.state_path, encoding="utf-8") as f:
                return json.load(f)
        except FileNotFoundError:
            # 初回起動では過去のジョブを通知しない。
            jobs = self.client.list_jobs(10)
            state = {"notified_job": max((j.get(1, 0) for j in jobs), default=0)}
            self._save(state)
            return state

    def _save(self, state=None):
        with open(self.state_path + ".tmp", "w", encoding="utf-8") as f:
            json.dump(state or self.state, f)
        os.replace(self.state_path + ".tmp", self.state_path)

    def tick(self):
        jobs = self.client.list_jobs(10)
        self._record_latest(jobs)
        self._notify_finished(jobs)
        if not os.path.exists(self.request_path):
            return
        if any(j.get(4, 0) in JOB_ACTIVE for j in jobs):
            return  # 実行中は投入できない。終わってから最新のコードで1回だけ投入する。
        job = self.client.enqueue(TARGET_ID)
        # enqueue.sh は要求ファイルが消えたあとに latest_job を読むので、先に書く。
        self._record_latest(self.client.list_jobs(10))
        os.remove(self.request_path)
        self.notify(f"🚀 ベンチを投入しました: Job #{job.get(1, '?')}\nコード: {self.code()}")

    def _record_latest(self, jobs):
        if jobs:
            write_latest_job(self.results_dir, max(j.get(1, 0) for j in jobs))

    def _notify_finished(self, jobs):
        finished = [j for j in jobs if j.get(4, 0) not in JOB_ACTIVE and j.get(1, 0) > self.state["notified_job"]]
        for summary in sorted(finished, key=lambda j: j.get(1, 0)):
            # 一覧の API には合否とログが含まれない。
            job = self.client.get_job(summary.get(1))
            passed = job.get(18, {}).get(1) == 1
            mark = "✅" if passed and job.get(4) == 4 else "❌"
            status = JOB_STATUS.get(job.get(4), "UNKNOWN")
            execution = job.get(18, {}).get(5, {})
            write_result(self.results_dir, job.get(1), "job.json", json.dumps({
                "job": job.get(1), "status": status, "passed": passed, "score": job.get(9),
                "code": self.code(), "log": execution.get(2, ""),
            }, ensure_ascii=False))
            self.notify(f"{mark} Job #{job.get(1)} {status} スコア: **{job.get(9, '-')}**\nコード: {self.code()}")
            self.state["notified_job"] = job.get(1)
            self._save()


def call_remote(host, operation):
    """接続先の鍵は log-access.sh の status / read / clear だけを実行できる。"""
    return run(
        "ssh", "-i", SSH_KEY, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new",
        "-o", "UserKnownHostsFile=/home/isucon/bench-bot/known_hosts", f"isucon@{host}", operation,
    )


class Reporter:
    def __init__(self, notify=send_discord, now=time.time, log_path=ACCESS_LOG, code=deployed_code, remotes=REMOTES, remote=call_remote, results_dir=RESULTS_DIR):
        self.notify, self.now, self.log_path, self.code, self.remotes, self.remote = notify, now, log_path, code, remotes, remote
        self.results_dir = results_dir

    def tick(self):
        try:
            stat = os.stat(self.log_path)
        except FileNotFoundError:
            return
        # 走行中はルーターの帯域を使わないよう、asia1 が止まるまで他のサーバーに接続しない。
        if stat.st_size == 0 or self.now() - stat.st_mtime < IDLE_SECONDS:
            return
        for host in self.remotes.values():
            _, age = self.remote(host, "status").split()
            if int(age) < IDLE_SECONDS:
                return
        with open(self.log_path, encoding="utf-8", errors="replace") as f:
            logs = {"asia1": f.read()}
        for name, host in self.remotes.items():
            logs[name] = self.remote(host, "read")
        if sum(len(text.splitlines()) for text in logs.values()) >= MIN_LOG_LINES:
            self._post(logs)
        run("sudo", "-n", "truncate", "-s", "0", self.log_path)
        for host in self.remotes.values():
            self.remote(host, "clear")

    def _alp(self, text):
        return run(
            "/usr/local/bin/alp", "json", "--sort", "sum", "--reverse",
            "--output", "count,method,uri,min,max,sum,avg,p99", "--format", "md", "-m", MATCHING, "--limit", "1000",
            input=text,
        )

    def _post(self, logs):
        logs = {name: text.strip() for name, text in logs.items() if text.strip()}
        table = self._alp("\n".join(logs.values()))
        lines = [line for text in logs.values() for line in text.splitlines()]
        times = sorted(json.loads(line).get("time", "?")[11:19] for line in lines)
        servers = " / ".join(f"{name} {len(text.splitlines())}" for name, text in logs.items())
        errors = sum('"status":5' in line for line in lines)
        header = f"📊 alp 3サーバー集約 {times[0]}〜{times[-1]} UTC / {len(lines)} リクエスト ({servers}) / 5xx: {errors}\nコード: {self.code()}\n"
        rows, budget = [], 1900 - len(header)
        for row in table.splitlines():
            budget -= len(row) + 1
            if budget < 0:
                break
            rows.append(row)
        sections = [f"# 全サーバー\n\n{table}"] + [f"# {name}\n\n{self._alp(text)}" for name, text in logs.items()]
        report = "\n\n".join(sections)
        latest = read_latest_job(self.results_dir)
        if latest:
            write_result(self.results_dir, latest, "alp.md", header + "\n" + report + "\n")
        self.notify(header + "```\n" + "\n".join(rows) + "\n```", ("alp.md", report))


def stop_after_contest():
    # 競技終了後は環境の操作が禁止され、追試で再起動もされるので、起動していても何もしない。
    while time.time() >= CONTEST_END:
        time.sleep(3600)


def read_job_result(results_dir, job_id):
    try:
        with open(os.path.join(results_dir, str(job_id), "job.json"), encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return None


def print_job(job_id, result):
    print(f"Job #{job_id} status={result['status']} passed={str(result['passed']).lower()} score={result['score']}")
    print(f"コード: {result['code']}")
    print("\n--- ベンチのログ ---")
    print(result["log"].strip() or "(なし)")


def print_saved_alp(results_dir, job_id):
    print("\n--- alp ---")
    try:
        with open(os.path.join(results_dir, str(job_id), "alp.md"), encoding="utf-8") as f:
            print(f.read().strip())
    except FileNotFoundError:
        print("(この走行の alp はありません)")


def exit_code(result):
    return 0 if result["passed"] and result["status"] == "FINISHED" else 1


def wait_until(condition, timeout, sleep=time.sleep, now=time.time):
    deadline = now() + timeout
    while not condition():
        if now() >= deadline:
            return False
        sleep(POLL_SECONDS)
    return True


def command_enqueue(results_dir=RESULTS_DIR, request_path=REQUEST_PATH, sleep=time.sleep, now=time.time):
    """ベンチを要求して、走行が終わるまで待って結果を標準出力に出す。alp は provisioning/alp.sh fetch で取る。"""
    if now() >= CONTEST_END:
        print("競技が終了しているので実行しません", file=sys.stderr)
        return 2
    open(request_path, "a").close()
    print("ベンチの実行を要求しました。実行中のベンチがあれば、その完了後に投入します。", flush=True)
    if not wait_until(lambda: not os.path.exists(request_path), JOB_WAIT_SECONDS, sleep, now):
        print("ベンチを投入できませんでした。bench-bot のエラーを確認してください。", file=sys.stderr)
        return 2
    job_id = read_latest_job(results_dir)
    print(f"Job #{job_id} を投入しました。完了を待っています。", flush=True)
    if not wait_until(lambda: read_job_result(results_dir, job_id), JOB_WAIT_SECONDS, sleep, now):
        print(f"Job #{job_id} の完了を確認できませんでした。", file=sys.stderr)
        return 2
    result = read_job_result(results_dir, job_id)
    print()
    print_job(job_id, result)
    return exit_code(result)


def command_result(job_id=None, results_dir=RESULTS_DIR):
    job_id = job_id or read_latest_job(results_dir)
    result = read_job_result(results_dir, job_id) if job_id else None
    if not result:
        print(f"Job #{job_id} の結果はありません", file=sys.stderr)
        return 2
    print_job(job_id, result)
    print_saved_alp(results_dir, job_id)
    return exit_code(result)


def main():
    stop_after_contest()
    from isuxbench import IsuxportalClient

    workers = [Controller(IsuxportalClient()), Reporter()]
    send_discord("🤖 bench-bot 起動")
    last_errors = {}
    while True:
        stop_after_contest()
        for worker in workers:
            name = type(worker).__name__
            try:
                worker.tick()
                last_errors.pop(name, None)
            except Exception as e:
                message = f"{type(e).__name__}: {e}"
                print(f"{name}: {message}", flush=True)
                # 同じエラーを繰り返し通知しない (Cookie 切れなど)。
                if last_errors.get(name) != message:
                    last_errors[name] = message
                    try:
                        send_discord(f"⚠️ bench-bot エラー ({name}): {message}")
                    except Exception as notify_error:
                        print(f"notify failed: {notify_error}", flush=True)
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    if sys.argv[1:] == ["enqueue"]:
        sys.exit(command_enqueue())
    if sys.argv[1:2] == ["result"]:
        sys.exit(command_result(int(sys.argv[2]) if len(sys.argv) > 2 else None))
    main()
