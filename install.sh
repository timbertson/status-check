#!/bin/bash
set -eu
mkdir -p "$1/bin"
cp --dereference main.native "$1"/bin/status-check
