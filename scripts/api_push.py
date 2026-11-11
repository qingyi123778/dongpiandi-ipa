"""通过 GitHub Contents API 提交文件（绕开本机 git push 的 502 代理问题）。
用法: python api_push.py <owner/repo> <token_file> <local_root> [paths...]
不传 paths 则提交 root 下所有受控文件。
"""
import base64
import json
import os
import sys
import urllib.request

API = "https://api.github.com"


def req(method, url, token, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header("Authorization", "token " + token)
    r.add_header("Accept", "application/vnd.github+json")
    r.add_header("User-Agent", "dpd-build")
    if data:
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            body = resp.read().decode()
            return resp.status, (json.loads(body) if body.strip() else {})
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode() or "{}")


def get_sha(repo, token, path):
    st, d = req("GET", f"{API}/repos/{repo}/contents/{path}", token)
    if st == 200 and isinstance(d, dict):
        return d.get("sha")
    return None


def put_file(repo, token, path, local_path, message):
    with open(local_path, "rb") as fh:
        raw = fh.read()
    payload = {
        "message": message,
        "content": base64.b64encode(raw).decode(),
        "branch": "main",
    }
    sha = get_sha(repo, token, path)
    if sha:
        payload["sha"] = sha
    st, d = req("PUT", f"{API}/repos/{repo}/contents/{path}", token, payload)
    return st, d.get("commit", {}).get("sha", ""), d.get("message", "")


def main():
    repo = sys.argv[1]
    token = open(sys.argv[2]).read().strip()
    root = sys.argv[3]
    targets = sys.argv[4:]

    if not targets:
        targets = []
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in {".git", "build", "DongPianDi.xcodeproj", "__pycache__"}]
            for fn in filenames:
                full = os.path.join(dirpath, fn)
                targets.append(os.path.relpath(full, root).replace("\\", "/"))

    ok = 0
    for rel in sorted(targets):
        full = os.path.join(root, rel)
        if not os.path.isfile(full):
            print("SKIP(missing)", rel)
            continue
        st, sha, msg = put_file(repo, token, rel, full, f"sync {rel}")
        flag = "OK " if st in (200, 201) else "ERR"
        print(f"{flag} {st} {rel} {sha[:8] if sha else ''} {msg if st not in (200,201) else ''}")
        if st in (200, 201):
            ok += 1
    print(f"\n{ok}/{len(targets)} files pushed")


if __name__ == "__main__":
    main()
