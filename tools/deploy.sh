#!/usr/bin/env bash
# Copies the mod to ~/Zomboid/mods (what the game loads) and ~/Zomboid/Workshop (what the Workshop uploader reads).
if [ ! -d ServerEventManager/Contents ]; then
  echo "run from repo root: ServerEventManager/Contents not found" >&2
  exit 1
fi
T="$HOME/Zomboid/mods/ServerEventManager"
rm -rf "$T"
cp -r ServerEventManager/Contents/mods/ServerEventManager "$T"
W="$HOME/Zomboid/Workshop/ServerEventManager"
rm -rf "$W"
cp -r ServerEventManager "$W"
echo deployed
