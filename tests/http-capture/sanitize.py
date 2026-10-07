"""sanitize.py OUT: reduce a game session's WinHTTP trace to method, host, path and status.

Reads the game's output (WINEDEBUG=+winhttp) on stdin and keeps, in memory only, what each
request was and how it was answered: method, host, path without its query and with identifiers
masked, the HTTP status, or none if no status line was read. Header values, bodies and queries,
which carry tokens, signed download URLs and account identifiers, never leave this process.
Writes OUT/http.txt and OUT/http.json (updated every 10 s and at the end) and passes through to
stdout only xgameruntime's own log lines, which carry no tokens, and the runner's exit status.

The correlation is a reconstruction: with many requests at once on reused handles, a status can
go to the wrong request, and "none" then does not mean that a request got no answer. The
runtime's own failures are in its log ("WinHTTP error").

WinHTTP's traces name the request handle in API calls but not in the status line, so requests
are followed per thread: the connection a handle opens, the task WinHttpReceiveResponse queues,
the pool thread that runs it, and the status line read on that thread.
"""
import json
import re
import sys
import time
from pathlib import Path

WINE = re.compile(r"^(?:[0-9a-f]+:)?([0-9a-f]{4,}):(trace|fixme|err|warn):([a-z0-9_.]+):(\S+)\s?(.*)$")
RUNTIME = re.compile(r"^\[\d+\] \((?:info|err|warn|fixme|trace)\) \S+")
HANDLE = re.compile(r"^([0-9A-Fa-f]+)\b")
STRING = re.compile(r'L"((?:[^"\\]|\\.)*)"')
# WinHttpOpenRequest( hconnect, verb, object, ...): either string may be (null).
OPEN = re.compile(r'^([0-9A-Fa-f]+), (L"(?:[^"\\]|\\.)*"|\(null\)), (L"(?:[^"\\]|\\.)*"|\(null\))')
GUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")


def mask_path(path):
    """The path without query or fragment, identifiers masked."""
    path = re.split(r"[?#]", path, maxsplit=1)[0]
    path = GUID.sub("{guid}", path)
    path = re.sub(r"\((?:xuid|gt|gamertag)\)?\([^)]*\)", "(*)", path, flags=re.I)
    path = re.sub(r"\(([^)]*)\)", "(*)", path)
    segments = []
    for segment in path.split("/"):
        if re.search(r"\d{6,}", segment) or len(segment) > 32:
            segment = "*"
        segments.append(segment)
    return "/".join(segments)


class Capture:
    def __init__(self, out):
        self.out = out
        self.start = time.monotonic()
        self.sessions = set()   # session handles
        self.connects = {}      # connect handle -> host
        self.requests = {}      # request handle -> (method, host, path)
        self.thread_connect = {}  # thread -> host of its last WinHttpConnect
        self.thread_open = {}   # thread -> request just opened, waiting for its handle
        self.thread_current = {}  # thread -> request handle whose reply it reads
        self.thread_last = {}   # thread -> its last WinHTTP API call
        self.tasks = {}         # receive task -> request handle
        self.table = {}         # (method, host, path) -> {"first": s, "count": n, "status": {}}

    def entry(self, key):
        if key not in self.table:
            self.table[key] = {"first": round(time.monotonic() - self.start, 1), "count": 0, "status": {}}
        return self.table[key]

    def line(self, tid, function, args):
        handle = HANDLE.match(args)
        handle = handle.group(1).lstrip("0").lower() if handle else None
        if function == "WinHttpConnect":
            strings = STRING.findall(args)
            if handle:
                self.sessions.add(handle)
            if strings:
                self.thread_connect[tid] = strings[0].lower()
        elif function == "WinHttpOpenRequest":
            match = OPEN.match(args)
            host = self.connects.get(handle) or self.thread_connect.get(tid)
            if handle and host:
                self.connects[handle] = host
            if host and match:
                unquote = lambda field: field[2:-1] if field.startswith('L"') else ""
                method, target = unquote(match.group(2)) or "GET", unquote(match.group(3)) or "/"
                self.thread_open[tid] = (method.upper(), host, mask_path(target))
        elif function == "WinHttpReceiveResponse":
            if handle:
                self.thread_current[tid] = handle
        elif function == "queue_task":
            # Only the task WinHttpReceiveResponse queues just before, on the same thread.
            match = re.match(r"queueing ([0-9A-Fa-f]+) in", args)
            current = self.thread_current.get(tid)
            if match and current and self.thread_last.get(tid) == "WinHttpReceiveResponse":
                self.tasks[match.group(1).lstrip("0").lower()] = current
        elif function.startswith("task_") and args.startswith("running "):
            task = args.split()[1].lstrip("0").lower()
            if task in self.tasks:
                self.thread_current[tid] = self.tasks.pop(task)
        elif function == "read_reply" and "status code" in args:
            match = re.search(r'status code \[L"(\d{3})"\]', args)
            request = self.requests.get(self.thread_current.get(tid))
            if match and request:
                status = self.entry(request)["status"]
                status[match.group(1)] = status.get(match.group(1), 0) + 1
        elif function == "WinHttpCloseHandle" and handle:
            # Handles are small numbers that WinHTTP hands out again once closed.
            self.requests.pop(handle, None)
            self.connects.pop(handle, None)
            self.sessions.discard(handle)
        # The first call on a thread with a handle it has not seen after WinHttpOpenRequest
        # is on the new request (WinHttpSetOption, WinHttpAddRequestHeaders, WinHttpSendRequest).
        if function.startswith("WinHttp") and function != "WinHttpOpenRequest" and handle and \
                tid in self.thread_open and handle not in self.requests and handle not in self.connects and \
                handle not in self.sessions:
            request = self.thread_open.pop(tid)
            self.requests[handle] = request
            self.entry(request)["count"] += 1
        if function.startswith("WinHttp"):
            self.thread_last[tid] = function

    def write(self):
        rows = sorted(self.table.items(), key=lambda item: item[1]["first"])
        lines = ["%7s %5s  %-6s %-45s %-60s %s" % ("first", "count", "method", "host", "path", "status")]
        for (method, host, path), data in rows:
            answered = sum(data["status"].values())
            status = " ".join("%s:%d" % item for item in sorted(data["status"].items()))
            if data["count"] > answered:
                status = (status + " " if status else "") + "none:%d" % (data["count"] - answered)
            lines.append("%6.1fs %5d  %-6s %-45s %-60s %s" % (data["first"], data["count"], method, host, path, status))
        (self.out / "http.txt").write_text("\n".join(lines) + "\n")
        (self.out / "http.json").write_text(json.dumps(
            [{"method": m, "host": h, "path": p, **d} for (m, h, p), d in rows], indent=1) + "\n")


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    capture = Capture(out)
    last = time.monotonic()
    for raw in sys.stdin.buffer:
        text = raw.decode("utf-8", "replace").rstrip("\r\n")
        match = WINE.match(text)
        if match:
            tid, level, channel, function, args = match.groups()
            if channel == "winhttp" and level == "trace":
                capture.line(tid, function, args)
        elif RUNTIME.match(text) or text.startswith("exit status "):
            print(text, flush=True)
        if time.monotonic() - last > 10:
            capture.write()
            last = time.monotonic()
    capture.write()


if __name__ == "__main__":
    main()
