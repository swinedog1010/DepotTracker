import json
import os
import tempfile
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CREDENTIALS_GPG_PATH = os.path.join(SCRIPT_DIR, "credentials.json.gpg")

def test_decrypt():
    if not os.path.isfile(CREDENTIALS_GPG_PATH):
        print("credentials.json.gpg not found")
        return

    ramdir = tempfile.gettempdir()
    fd, target = tempfile.mkstemp(prefix="test.cred-", suffix=".json", dir=ramdir)
    os.close(fd)

    pass_args = []
    pass_file = os.path.join(SCRIPT_DIR, ".gpg_passphrase")
    env_pass = os.environ.get("DEPOT_GPG_PASS")
    if env_pass:
        pass_args = ["--batch", "--yes", "--passphrase", env_pass, "--pinentry-mode", "loopback"]
    elif os.path.isfile(pass_file):
        pass_args = ["--batch", "--yes", "--passphrase-file", pass_file, "--pinentry-mode", "loopback"]

    result = subprocess.run(
        ["gpg", *pass_args, "--quiet", "--decrypt", "--output", target, CREDENTIALS_GPG_PATH],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE
    )
    if result.returncode == 0:
        with open(target, "r") as f:
            data = json.load(f)
        print("DECRYPTED SUCCESS. USER:", data.get("smtp_user"))
        print("PASS LENGTH:", len(data.get("smtp_pass", "")))
        print("PASS contains spaces?", " " in data.get("smtp_pass", ""))
    else:
        print("DECRYPT FAILED:", result.stderr.decode("utf-8"))

test_decrypt()
