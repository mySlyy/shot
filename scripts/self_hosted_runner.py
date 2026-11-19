#!/usr/bin/env python3
"""Self-hosted GitHub Actions runner for mySlyy/shot on a Mac (Apple Silicon).

Runs the "Slyy Shot release" workflow (.github/workflows/slyy-shot.yml) when
the repo variable SHOT_RUNNER selects it (see README "Release runner").

Isolation (mySlyy/shot is public, the org is on the Free plan):
- dedicated hidden standard user "ghrunner", no password, no login shell
- own primary group "ghrunner" (NOT staff): /Users/<you> is drwxr-x--- staff,
  a staff member could read your files
- home 700, runner + work dir inside it
- system LaunchDaemon as ghrunner with SessionCreate (codesign needs a
  security session; no GUI login of ghrunner required)
- registration token fetched with the invoking user's gh login and passed by
  environment (ACTIONS_RUNNER_INPUT_TOKEN), never on the command line
- runner tarball checked against the SHA-256 GitHub publishes in the release

Usage (as root, gh logged in for the invoking user):
  sudo python3 scripts/self_hosted_runner.py install
  sudo python3 scripts/self_hosted_runner.py uninstall [--delete-user]
  python3 scripts/self_hosted_runner.py status
"""
import argparse
import hashlib
import json
import os
import platform
import pwd
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

REPO = "mySlyy/shot"
USER = "ghrunner"  # macOS account and primary group of the runner
HOME = f"/Users/{USER}"
RUNNER_DIR = f"{HOME}/actions-runner"
LABEL = "ai.slyy.ghrunner.shot"  # launchd label
PLIST = f"/Library/LaunchDaemons/{LABEL}.plist"
RUNNER_LABELS = "slyy-shot"  # extra label; self-hosted, macOS, ARM64 are added by GitHub
RUNNER_NAME = "slyy-shot-mac"  # fixed, neutral: shows in public job logs (no hostname / personal name)
ID_RANGE = range(600, 700)  # uid/gid for the runner (below 500 = system, 501+ = humans)


def run(cmd, **kw):
    """Run a command, fail loudly; returns stdout (str)."""
    kw.setdefault("check", True)
    kw.setdefault("text", True)
    kw.setdefault("capture_output", True)
    try:
        return subprocess.run(cmd, **kw).stdout
    except subprocess.CalledProcessError as e:
        sys.exit(f"failed: {' '.join(cmd)}\n{e.stderr or e.stdout}")


def as_user(cmd, env=None):
    """Run as the runner user (runner files must be owned by it). Drops root via
    setuid/setgid (no supplementary groups); env is passed directly, so secrets
    never appear in a process list (sudo env VAR=... would show them)."""
    base = {"HOME": HOME, "USER": USER, "LOGNAME": USER, "LANG": "de_DE.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
    return run(cmd, cwd=RUNNER_DIR, user=USER, group=USER, extra_groups=[], env={**base, **(env or {})})


def gh(*args):
    """gh CLI as the user who called sudo (root has no gh login)."""
    caller = os.environ.get("SUDO_USER")
    if not caller or caller == "root":
        sys.exit("run with sudo from your own account (gh must be logged in there)")
    return run(["sudo", "-u", caller, "-H", "gh", *args]).strip()


def need_root():
    if os.geteuid() != 0:
        sys.exit("needs root: sudo python3 scripts/self_hosted_runner.py ...")


def dscl_ids(kind, key):
    out = run(["dscl", ".", "-list", f"/{kind}", key])
    return {int(p[1]) for p in (l.split() for l in out.splitlines()) if len(p) == 2 and p[1].lstrip("-").isdigit()}


def exists(kind, name):
    return subprocess.run(["dscl", ".", "-read", f"/{kind}/{name}"], capture_output=True).returncode == 0


def create_user():
    """Hidden standard user with its own group; no password, no shell, not in staff/admin."""
    if exists("Users", USER):
        print(f"user {USER} exists")
    else:
        used = dscl_ids("Users", "UniqueID") | dscl_ids("Groups", "PrimaryGroupID")
        xid = next(i for i in ID_RANGE if i not in used)  # same number for uid and gid
        g, u = f"/Groups/{USER}", f"/Users/{USER}"
        run(["dscl", ".", "-create", g])
        run(["dscl", ".", "-create", g, "PrimaryGroupID", str(xid)])
        run(["dscl", ".", "-create", g, "RealName", "GitHub Runner"])
        run(["dscl", ".", "-create", u])
        for k, v in [("UniqueID", xid), ("PrimaryGroupID", xid), ("UserShell", "/usr/bin/false"),
                     ("NFSHomeDirectory", HOME), ("RealName", "GitHub Runner"), ("IsHidden", 1)]:
            run(["dscl", ".", "-create", u, k, str(v)])
        run(["dscl", ".", "-create", u, "Password", "*"])  # no password: cannot log in
        print(f"created user {USER} (uid/gid {xid})")
    os.makedirs(HOME, exist_ok=True)
    pw = pwd.getpwnam(USER)
    os.chown(HOME, pw.pw_uid, pw.pw_gid)
    os.chmod(HOME, 0o700)
    # Must not reach your files through group staff (or admin).
    for grp in ("staff", "admin"):
        r = run(["dsmemberutil", "checkmembership", "-U", USER, "-G", grp])
        if "is a member" in r:
            sys.exit(f"{USER} is a member of {grp}; refusing (would read other users' files)")


def runner_release():
    """Latest actions/runner osx-arm64 tarball URL + published SHA-256."""
    with urllib.request.urlopen("https://api.github.com/repos/actions/runner/releases/latest", timeout=30) as r:
        rel = json.load(r)
    arch = "arm64" if platform.machine() == "arm64" else "x64"
    asset = next(a for a in rel["assets"] if re.fullmatch(rf"actions-runner-osx-{arch}-[\d.]+\.tar\.gz", a["name"]))
    m = re.search(rf"<!-- BEGIN SHA osx-{arch} -->([0-9a-f]{{64}})<!-- END SHA osx-{arch} -->", rel["body"])
    if not m:
        sys.exit("no SHA-256 for the runner in the release notes; refusing")
    digest = asset.get("digest", "")  # newer API: "sha256:<hex>", cross-check when present
    if digest and digest != f"sha256:{m.group(1)}":
        sys.exit("runner SHA-256 in release notes and asset digest differ; refusing")
    return asset["browser_download_url"], m.group(1)


def install_runner():
    if os.path.exists(f"{RUNNER_DIR}/.runner"):
        print("runner already configured (uninstall first to re-register)")
        return
    url, sha = runner_release()
    print(f"downloading {url}")
    with tempfile.TemporaryDirectory() as tmp:
        tgz = os.path.join(tmp, "runner.tar.gz")
        urllib.request.urlretrieve(url, tgz)
        h = hashlib.sha256(open(tgz, "rb").read()).hexdigest()
        if h != sha:
            sys.exit(f"SHA-256 mismatch: got {h}, want {sha}")
        os.makedirs(RUNNER_DIR, exist_ok=True)
        # bsdtar refuses absolute paths and ".." escapes by default (system Python 3.9 has no tarfile filter)
        run(["tar", "-xzf", tgz, "-C", RUNNER_DIR])
    run(["chown", "-R", f"{USER}:{USER}", RUNNER_DIR])
    token = gh("api", "-X", "POST", f"repos/{REPO}/actions/runners/registration-token", "--jq", ".token")
    as_user(["./config.sh", "--unattended", "--replace", "--url", f"https://github.com/{REPO}",
             "--name", RUNNER_NAME, "--labels", RUNNER_LABELS, "--work", "_work"],
            env={"ACTIONS_RUNNER_INPUT_TOKEN": token})
    print(f"registered runner {RUNNER_NAME} on {REPO}")


def install_daemon():
    """System LaunchDaemon: starts at boot, restarts on exit, runs as ghrunner."""
    import plistlib
    plist = {
        "Label": LABEL,
        "UserName": USER,
        "GroupName": USER,
        "ProgramArguments": [f"{RUNNER_DIR}/run.sh"],
        "WorkingDirectory": RUNNER_DIR,
        "RunAtLoad": True,
        "KeepAlive": True,
        "SessionCreate": True,  # security session: codesign / temp keychains work without GUI login
        "ProcessType": "Interactive",
        "EnvironmentVariables": {
            "HOME": HOME,
            "LANG": "de_DE.UTF-8",
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        },
        "StandardOutPath": f"{RUNNER_DIR}/_diag/launchd.log",
        "StandardErrorPath": f"{RUNNER_DIR}/_diag/launchd.log",
    }
    os.makedirs(f"{RUNNER_DIR}/_diag", exist_ok=True)
    run(["chown", f"{USER}:{USER}", f"{RUNNER_DIR}/_diag"])
    subprocess.run(["launchctl", "bootout", f"system/{LABEL}"], capture_output=True)
    with open(PLIST, "wb") as f:
        plistlib.dump(plist, f)
    os.chown(PLIST, 0, 0)
    os.chmod(PLIST, 0o644)
    run(["launchctl", "bootstrap", "system", PLIST])
    print(f"started {LABEL}")


def uninstall(delete_user):
    subprocess.run(["launchctl", "bootout", f"system/{LABEL}"], capture_output=True)
    if os.path.exists(PLIST):
        os.remove(PLIST)
    if os.path.exists(f"{RUNNER_DIR}/.runner"):
        token = gh("api", "-X", "POST", f"repos/{REPO}/actions/runners/remove-token", "--jq", ".token")
        as_user(["./config.sh", "remove"], env={"ACTIONS_RUNNER_INPUT_TOKEN": token})
        print(f"deregistered runner {RUNNER_NAME}")
    if delete_user and exists("Users", USER):
        run(["dscl", ".", "-delete", f"/Users/{USER}"])
        run(["dscl", ".", "-delete", f"/Groups/{USER}"])
        shutil.rmtree(HOME, ignore_errors=True)
        print(f"deleted user {USER} and {HOME}")


def status():
    r = subprocess.run(["launchctl", "print", f"system/{LABEL}"], capture_output=True, text=True)
    state = re.search(r"^\s*state = (.+)$", r.stdout, re.M)
    print(f"daemon: {state.group(1) if state else 'not loaded'}")
    r = subprocess.run(["gh", "api", f"repos/{REPO}/actions/runners", "--jq",
                        r'.runners[] | "\(.name): \(.status), busy=\(.busy), labels=\([.labels[].name] | join(","))"'],
                       capture_output=True, text=True)
    print(r.stdout.strip() or r.stderr.strip() or "no runners registered")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("install")
    u = sub.add_parser("uninstall")
    u.add_argument("--delete-user", action="store_true", help=f"also delete user/group {USER} and {HOME}")
    sub.add_parser("status")
    a = p.parse_args()
    if a.cmd == "status":
        return status()
    need_root()
    if a.cmd == "install":
        create_user()
        install_runner()
        install_daemon()
        status()
    else:
        uninstall(a.delete_user)


if __name__ == "__main__":
    main()
