#!/usr/bin/env python3
"""
generate_printer_secrets.py

Idempotent secret generator/merger for the repo.

Behavior:
- Merge a set of printer-related secret keys into the target YAML file (default: ansible/inventory/secrets.yml).
- Only creates missing keys (does not duplicate or append multiple entries).
- Writes the file back in simple key: value YAML style (top-level mapping).
- Optionally creates/patches Kubernetes Secrets in the `print` namespace (requires kubectl in PATH and kubeconfig context that can access the cluster).

Usage (run locally on masternode where your repo and kubectl are available):
  ./kustomize/printer/generate_printer_secrets.py --file ansible/inventory/secrets.yml --apply-k8s

Security notes:
- The script writes plaintext YAML by default. You said you will encrypt the vault later — do that after you are satisfied.
- The script will not overwrite existing non-empty values unless --force is provided.

"""

from __future__ import annotations
import os
import sys
import argparse
import secrets
import base64
import subprocess
import shutil
import tempfile
import re


DEFAULT_TARGET = "ansible/inventory/secrets.yml"

# Keys we will ensure exist (top-level keys). You can edit this list if you want
DESIRED_KEYS = {
    # paperless
    "paperless_secret_key": None,  # Auto-generate if missing
    "paperless_db_user": "paperless",
    "paperless_db_pass": None,  # generate if missing
    "paperless_db_host": "postgres-service",
    "paperless_db_name": "paperless",
    "paperless_redis": "redis://redis-service:6379/0",
    # scanner smb creds
    "scanner_user": "scanneruser",
    "scanner_password": None,
    # cloudflare token
    "vault_cloudflare_api_token": None,
    # windows ansible vault password
    "vault_windows_ansible_password": None,
}



def random_password(nbytes: int = 18) -> str:
    # produce a URL-safe base64 string without padding
    return base64.urlsafe_b64encode(secrets.token_bytes(nbytes)).decode("utf-8").rstrip("=")


def read_simple_yaml(path: str) -> dict:
    """
    Read a very small subset of YAML: top-level mapping of scalar keys to scalar values.
    If PyYAML is available, prefer it. Otherwise, fall back to line parsing.
    """
    data = {}
    if not os.path.exists(path):
        return data
    try:
        import yaml
    except Exception:
        yaml = None
    if yaml:
        with open(path, "r") as f:
            try:
                content = yaml.safe_load(f) or {}
            except Exception:
                # fall back to simple parse
                content = None
        if isinstance(content, dict):
            # ensure all values are strings
            for k, v in content.items():
                if v is None:
                    data[str(k)] = ""
                else:
                    data[str(k)] = str(v)
            return data
    # Simple parse: lines like key: value
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = re.match(r"^([A-Za-z0-9_\-]+)\s*:\s*(.*)$", line)
            if m:
                k = m.group(1)
                v = m.group(2)
                # remove surrounding quotes if present
                if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
                    v = v[1:-1]
                data[k] = v
    return data


def write_simple_yaml(path: str, mapping: dict) -> None:
    # write atomically
    d = os.path.dirname(path)
    if d and not os.path.exists(d):
        os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="secrets-", suffix=".yml", dir=d or None)
    try:
        with os.fdopen(fd, "w") as f:
            f.write("# Managed by generate_printer_secrets.py - do not commit plaintext if you want it secure\n")
            for k in sorted(mapping.keys()):
                v = mapping[k]
                # quote if value contains special chars
                if v is None:
                    v = ""
                v = str(v)
                if re.search(r"[:\n\r'#\"\\]", v):
                    # use single quotes and escape single quotes by doubling
                    v2 = v.replace("'", "''")
                    f.write(f"{k}: '{v2}'\n")
                else:
                    f.write(f"{k}: {v}\n")
        # move into place
        shutil.move(tmp, path)
    finally:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except Exception:
                pass


def kubectl_apply_secret(name: str, namespace: str, literals: dict) -> bool:
    """
    Create or patch a Kubernetes secret using kubectl. Returns True on success.
    Uses kubectl create secret generic ... --dry-run=client -o yaml | kubectl apply -f -
    """
    if shutil.which("kubectl") is None:
        print("kubectl not found in PATH; skipping k8s secret apply")
        return False
    parts = ["kubectl", "create", "secret", "generic", name, f"-n", namespace]
    for k, v in literals.items():
        parts.append(f"--from-literal={k}={v}")
    parts.extend(["--dry-run=client", "-o", "yaml"])
    try:
        p1 = subprocess.run(parts, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, text=True)
        p2 = subprocess.run(["kubectl", "apply", "-f", "-"], input=p1.stdout, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, text=True)
        print(p2.stdout)
        return True
    except subprocess.CalledProcessError as e:
        print("kubectl error:", e.stderr)
        return False


def ensure_keys(existing: dict, force: bool = False) -> (dict, dict):
    """
    Ensure DESIRED_KEYS are present in existing map. Returns (newmap, changed_map)
    changed_map contains only keys that changed/added.
    """
    out = dict(existing)
    changed = {}
    for key, default in DESIRED_KEYS.items():
        cur = out.get(key, "")
        if cur not in (None, "") and not force:
            continue
        # need to generate
        if default is None:
            # generate secure random value
            val = random_password(24)
        else:
            val = str(default)
        out[key] = val
        changed[key] = val
    return out, changed


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--file", "-f", default=DEFAULT_TARGET, help="Target YAML file to update (default: ansible/inventory/secrets.yml)")
    p.add_argument("--apply-k8s", action="store_true", help="Also create/patch Kubernetes Secrets in namespace 'print' using kubectl")
    p.add_argument("--force", action="store_true", help="Force overwrite existing keys with generated values")
    p.add_argument("--yes", "-y", action="store_true", help="Auto-approve writing file and applying k8s secrets")
    args = p.parse_args(argv)

    path = args.file
    print("Target secret file:", path)

    existing = read_simple_yaml(path) if os.path.exists(path) else {}
    print("Loaded existing keys:", list(existing.keys()))

    merged, changed = ensure_keys(existing, force=args.force)
    if not changed:
        print("No new keys needed; file is up to date. Exiting.")
        # Still optionally ensure k8s secrets exist if requested
        if args.apply_k8s:
            print("Applying k8s secrets from existing file (no changes)...")
            # build literals for paperless and scanner
            paperless_literals = {
                "PAPERLESS_SECRET_KEY": merged.get("paperless_secret_key", ""),
                "PAPERLESS_DBUSER": merged.get("paperless_db_user", "paperless"),
                "PAPERLESS_DBPASS": merged.get("paperless_db_pass", ""),
                "PAPERLESS_DBHOST": merged.get("paperless_db_host", "postgres-service"),
                "PAPERLESS_DBNAME": merged.get("paperless_db_name", "paperless"),
                "PAPERLESS_REDIS": merged.get("paperless_redis", "redis://redis-service:6379/0"),
            }
            scanner_literals = {
                "USER": merged.get("scanner_user","scanneruser"),
                "PASSWORD": merged.get("scanner_password",""),
            }
            kubectl_apply_secret("paperless-secret","print", paperless_literals)
            kubectl_apply_secret("scanner-smb","print", scanner_literals)
        return 0

    print("Keys to add/update:")
    for k, v in changed.items():
        print(f"  {k}: (hidden) -> will be set")

    if not args.yes:
        resp = input("Write updates to file and apply changes? [y/N]: ")
        if resp.lower() not in ("y","yes"):
            print("Aborting.")
            return 1

    write_simple_yaml(path, merged)
    print(f"Wrote updated secrets to {path}")

    if args.apply_k8s:
        print("Applying kubernetes secrets to namespace 'print' (requires kubectl)...")
        paperless_literals = {
            "PAPERLESS_DBUSER": merged.get("paperless_db_user","paperless"),
            "PAPERLESS_DBPASS": merged.get("paperless_db_pass",""),
            "PAPERLESS_DBHOST": merged.get("paperless_db_host","postgres-service"),
            "PAPERLESS_DBNAME": merged.get("paperless_db_name","paperless"),
            "PAPERLESS_REDIS": merged.get("paperless_redis","redis://redis-service:6379/0"),
        }
        scanner_literals = {
            "USER": merged.get("scanner_user","scanneruser"),
            "PASSWORD": merged.get("scanner_password",""),
        }
        ok1 = kubectl_apply_secret("paperless-secret","print", paperless_literals)
        ok2 = kubectl_apply_secret("scanner-smb","print", scanner_literals)
        if not (ok1 and ok2):
            print("Warning: one or more kubectl operations failed. Check kubectl context and permissions.")

    print("Done.")
    return 0


if __name__ == '__main__':
    sys.exit(main())
