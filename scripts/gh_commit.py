#!/usr/bin/env python3
"""
通过 GitHub API 提交文件（绕过 git 传输层 443 不稳定问题）。

流程：blob → tree → commit → update ref
用法： python3 gh_commit.py <repo_dir> <owner/repo> <branch> "<commit message>"
"""
import base64
import json
import os
import subprocess
import sys

REPO_DIR, REPO, BRANCH, MSG = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

SKIP_EXT = {'.pyc', '.tar.gz'}
SKIP_NAMES = {'.DS_Store'}
SKIP_DIRS = {'__pycache__', '.git'}


def gh(args, method="GET", payload=None):
    cmd = ["gh", "api"]
    if method != "GET":
        cmd += ["-X", method]
    cmd += args
    if payload is not None:
        cmd += ["--input", "-"]
        p = subprocess.run(cmd, input=json.dumps(payload), capture_output=True, text=True)
    else:
        p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"gh api failed: {p.stderr[:400]}")
    return json.loads(p.stdout) if p.stdout.strip() else {}


def collect_files(root):
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if fn in SKIP_NAMES or any(fn.endswith(e) for e in SKIP_EXT):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            out.append((rel, full))
    return sorted(out)


files = collect_files(REPO_DIR)
print(f"待提交 {len(files)} 个文件：")
for rel, _ in files:
    print("  -", rel)

# 1) 创建 blob
blobs = []
for rel, full in files:
    with open(full, "rb") as f:
        content = f.read()
    body = {"content": base64.b64encode(content).decode(), "encoding": "base64"}
    r = gh([f"repos/{REPO}/git/blobs"], "POST", body)
    blobs.append({"path": rel, "mode": "100755" if os.access(full, os.X_OK) else "100644",
                  "type": "blob", "sha": r["sha"]})
    print(f"  blob {rel} -> {r['sha'][:8]}")

# 2) 取 base tree（仓库为空则可能失败，容错）
try:
    ref = gh([f"repos/{REPO}/git/ref/heads/{BRANCH}"])
    base_sha = ref["object"]["sha"]
    commit = gh([f"repos/{REPO}/git/commits/{base_sha}"])
    base_tree = commit["tree"]["sha"]
    parent = base_sha
    print(f"base tree: {base_tree[:8]} (parent {parent[:8]})")
except Exception:
    base_tree, parent = None, None
    print("空仓库，创建首个 commit")

tree_payload = {"tree": blobs}
if base_tree:
    tree_payload["base_tree"] = base_tree
tree = gh([f"repos/{REPO}/git/trees"], "POST", tree_payload)
print(f"tree: {tree['sha'][:8]}")

# 3) commit
commit_payload = {"message": MSG, "tree": tree["sha"]}
if parent:
    commit_payload["parents"] = [parent]
new_commit = gh([f"repos/{REPO}/git/commits"], "POST", commit_payload)
print(f"commit: {new_commit['sha'][:8]}")

# 4) 更新 ref
if parent:
    gh([f"repos/{REPO}/git/refs/heads/{BRANCH}"], "PATCH", {"sha": new_commit["sha"]})
else:
    gh([f"repos/{REPO}/git/refs"], "POST",
       {"ref": f"refs/heads/{BRANCH}", "sha": new_commit["sha"]})
print(f"ref updated -> {BRANCH}")
print("DONE:", new_commit["sha"])
