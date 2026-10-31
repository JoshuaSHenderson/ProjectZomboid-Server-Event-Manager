#!/usr/bin/env bash
if [ ! -d ServerEventManager/Contents ]; then
  echo "run from repo root: ServerEventManager/Contents not found" >&2
  exit 1
fi
T="$HOME/Zomboid/mods/ServerEventManager"
rm -rf "$T"
cp -r ServerEventManager/Contents/mods/ServerEventManager "$T"
echo deployed
