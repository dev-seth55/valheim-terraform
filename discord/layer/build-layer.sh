#!/bin/bash
# Rebuilds pynacl-layer.zip (PyNaCl for Ed25519 verification of Discord
# requests). Only needed if you want a newer PyNaCl or a new Python runtime.
# Requires pip. Produces a Lambda layer for python3.12 on x86_64.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf python pynacl-layer.zip
pip install pynacl \
  --platform manylinux2014_x86_64 --python-version 3.12 --only-binary=:all: \
  -t python
zip -qr pynacl-layer.zip python
rm -rf python
ls -la pynacl-layer.zip
