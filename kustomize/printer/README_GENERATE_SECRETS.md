# Printer secrets generator

This script merges/generates printer-related credentials into your ansible/inventory/secrets.yml
and (optionally) applies them to Kubernetes as Secrets in the `print` namespace.

Files added:
- kustomize/printer/generate_printer_secrets.py

Usage (recommended run locally on your masternode):

1) Preview existing keys and run interactively:

   python3 kustomize/printer/generate_printer_secrets.py --file ansible/inventory/secrets.yml

   The script will prompt before writing. It only adds missing keys by default.

2) To also create/update Kubernetes Secrets in the `print` namespace (requires kubectl available and pointed at your cluster):

   python3 kustomize/printer/generate_printer_secrets.py --file ansible/inventory/secrets.yml --apply-k8s

3) To run non-interactively (approve automatically):

   python3 kustomize/printer/generate_printer_secrets.py --file ansible/inventory/secrets.yml --apply-k8s --yes

Notes and security
- The script writes plaintext YAML. You said you will encrypt the vault later — after you confirm the content, run:
    ansible-vault encrypt ansible/inventory/secrets.yml --ask-vault-pass

- The script is idempotent: it will only add missing keys (or overwrite if you pass --force). It will not duplicate entries.
- The script writes keys at the top-level of the YAML as simple key: value pairs. If your secrets.yml uses nested structures, review the output before encrypting.

Customization
- Edit the DESIRED_KEYS mapping at the top of the script to change which keys are managed and their defaults.

