#!/usr/bin/env python3
"""Run one command under a fail-closed Linux Tctl temperature guard."""

from __future__ import annotations

import argparse
import json
import math
import os
import signal
import subprocess
import sys
import time
from pathlib import Path


class StopRequested(BaseException):
    def __init__(self, signum: int) -> None:
        super().__init__(f"received signal {signum}")
        self.signum = signum


def find_tctl(root: Path = Path("/sys/class/hwmon")) -> Path:
    for entry in sorted(root.glob("hwmon*")):
        try:
            if (entry / "name").read_text(encoding="utf-8").strip() == "k10temp":
                sensor = entry / "temp1_input"
                int(sensor.read_text(encoding="utf-8").strip())
                return sensor
        except (OSError, ValueError):
            continue
    raise RuntimeError(f"no readable k10temp Tctl sensor under {root}")


def read_celsius(sensor: Path) -> float:
    return int(sensor.read_text(encoding="utf-8").strip()) / 1000.0


def session_members(session_id: int) -> list[tuple[int, int, str]]:
    """Return (pid, process-group, state) for one Linux process session."""
    members: list[tuple[int, int, str]] = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            stat_text = (entry / "stat").read_text(encoding="utf-8")
            fields = stat_text[stat_text.rfind(")") + 2 :].split()
            state = fields[0]
            process_group = int(fields[2])
            member_session = int(fields[3])
        except (FileNotFoundError, IndexError, OSError, ValueError):
            continue
        if member_session == session_id:
            members.append((int(entry.name), process_group, state))
    return members


def session_alive(session_id: int) -> bool:
    return any(state != "Z" for _, _, state in session_members(session_id))


def signal_session(session_id: int, signum: signal.Signals) -> None:
    """Signal every current process group in a guarded Linux session."""
    members = session_members(session_id)
    process_groups = {process_group for _, process_group, _ in members}
    process_groups.add(session_id)
    for process_group in process_groups:
        try:
            os.killpg(process_group, signum)
        except ProcessLookupError:
            pass

    # Cover a member that changed groups between the snapshot and killpg.
    for pid, _, state in members:
        if state == "Z":
            continue
        try:
            os.kill(pid, signum)
        except ProcessLookupError:
            pass


def stop_group(process: subprocess.Popen[bytes], grace_seconds: float) -> int:
    session_id = process.pid
    signal_session(session_id, signal.SIGTERM)
    deadline = time.monotonic() + grace_seconds
    while session_alive(session_id) and time.monotonic() < deadline:
        time.sleep(0.05)

    if session_alive(session_id):
        kill_deadline = time.monotonic() + grace_seconds
        while session_alive(session_id) and time.monotonic() < kill_deadline:
            signal_session(session_id, signal.SIGKILL)
            time.sleep(0.05)

    try:
        exit_code = process.wait(timeout=grace_seconds)
    except subprocess.TimeoutExpired as error:
        signal_session(session_id, signal.SIGKILL)
        raise RuntimeError("guarded process session could not be reaped") from error
    if session_alive(session_id):
        signal_session(session_id, signal.SIGKILL)
        raise RuntimeError("runnable descendants survived guarded-session cleanup")
    return exit_code


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--start-max-c", type=float)
    parser.add_argument("--warn-c", type=float, default=75.0)
    parser.add_argument("--critical-c", type=float, default=90.0)
    parser.add_argument("--poll-seconds", type=float, default=0.25)
    parser.add_argument("--grace-seconds", type=float, default=5.0)
    parser.add_argument("--log", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command:
        parser.error("a command is required after --")
    if not 0.0 < args.warn_c < args.critical_c < 100.0:
        parser.error("thresholds must satisfy 0 < warn < critical < 100")
    if args.start_max_c is not None and (
        not math.isfinite(args.start_max_c)
        or not 0.0 < args.start_max_c < args.critical_c
    ):
        parser.error("--start-max-c must satisfy 0 < start-max < critical")
    if not math.isfinite(args.poll_seconds) or args.poll_seconds <= 0.0:
        parser.error("--poll-seconds must be finite and positive")
    if not math.isfinite(args.grace_seconds) or args.grace_seconds <= 0.0:
        parser.error("--grace-seconds must be finite and positive")
    return args


def main() -> int:
    args = parse_args()
    try:
        sensor = find_tctl()
    except RuntimeError as error:
        print(f"thermal guard: {error}", file=sys.stderr)
        return 76

    if args.start_max_c is not None:
        try:
            start_temperature = read_celsius(sensor)
        except (OSError, ValueError) as error:
            print(f"thermal guard: Tctl is unreadable: {error}", file=sys.stderr)
            return 76
        if start_temperature > args.start_max_c:
            print(
                "thermal guard: "
                f"Tctl {start_temperature:.3f}C exceeds start limit "
                f"{args.start_max_c:.3f}C",
                file=sys.stderr,
            )
            return 77

    if args.log:
        args.log.parent.mkdir(parents=True, exist_ok=True)

    def emit(record: dict[str, object]) -> None:
        if args.log:
            with args.log.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(record, sort_keys=True) + "\n")

    def request_stop(signum: int, _frame: object) -> None:
        raise StopRequested(signum)

    watched_signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, watched_signals)
    old_handlers = {
        signum: signal.signal(signum, request_stop)
        for signum in watched_signals
    }
    try:
        process = subprocess.Popen(
            args.command,
            start_new_session=True,
            preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, old_mask),
        )
    except BaseException:
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
        raise
    started = time.monotonic()
    samples = 0
    maximum: float | None = None
    reason: str | None = None
    return_code: int | None = None
    residual_session_cleaned = False

    try:
        # A pending stop signal is delivered here only after process is assigned,
        # so its handler can always clean the new session.
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
        while process.poll() is None:
            samples += 1
            try:
                temperature = read_celsius(sensor)
            except (OSError, ValueError) as error:
                reason = f"Tctl became unreadable: {error}"
                emit(
                    {
                        "elapsed_s": time.monotonic() - started,
                        "sample": samples,
                        "sensor_ok": False,
                        "error": str(error),
                    }
                )
                break
            maximum = temperature if maximum is None else max(maximum, temperature)
            emit(
                {
                    "elapsed_s": time.monotonic() - started,
                    "sample": samples,
                    "sensor_ok": True,
                    "tctl_c": temperature,
                    "warn": temperature >= args.warn_c,
                }
            )
            if temperature >= args.critical_c:
                reason = (
                    f"Tctl {temperature:.3f}C reached critical threshold "
                    f"{args.critical_c:.3f}C"
                )
                break
            time.sleep(args.poll_seconds)

        if reason is not None:
            stop_group(process, args.grace_seconds)
            return_code = 75 if reason.startswith("Tctl ") else 76
        else:
            return_code = process.wait()
            if session_alive(process.pid):
                stop_group(process, args.grace_seconds)
                residual_session_cleaned = True
                reason = "guarded command left runnable descendants"
                return_code = 74
    except StopRequested as error:
        stop_group(process, args.grace_seconds)
        reason = str(error)
        return_code = 128 + error.signum
    except BaseException:
        if process.poll() is None or session_alive(process.pid):
            stop_group(process, args.grace_seconds)
        raise
    finally:
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)

    report = {
        "abort_reason": reason,
        "command_exit_code": process.returncode,
        "elapsed_s": time.monotonic() - started,
        "guard_exit_code": return_code,
        "max_tctl_c": maximum,
        "pid": process.pid,
        "residual_session_cleaned": residual_session_cleaned,
        "samples": samples,
    }
    print(json.dumps(report, sort_keys=True))
    return int(return_code)


if __name__ == "__main__":
    raise SystemExit(main())
