#!/usr/bin/env bash
# Boots an isolated local dedicated server with this mod. Usage: tools/test-server.sh [extra Mods;...]
# Never use ProjectZomboidServer.bat: it drops all arguments and runs on the real ~/Zomboid.
# user.home points at a throwaway folder, so the default path cannot reach real game data.
set -e
[ -d ServerEventManager/Contents ] || { echo "run from repo root" >&2; exit 1; }
HOME_DIR="${SEM_HOME:-/s/ProjectZomboid-Server-Event-Manager/.testserver}"
CACHE="$HOME_DIR/Zomboid"
GAME="/d/SteamLibrary/steamapps/common/ProjectZomboid"
mkdir -p "$CACHE/mods" "$CACHE/Server"
rm -rf "$CACHE/mods/ServerEventManager"
cp -r ServerEventManager/Contents/mods/ServerEventManager "$CACHE/mods/"
# SEM_SELFTEST=1: also runs tests/selftest.lua inside real PZ Lua at server start; results print as [SEM-TEST]
[ -n "$SEM_SELFTEST" ] && cp tests/selftest.lua "$CACHE/mods/ServerEventManager/42/media/lua/server/SEM/ZSelfTest.lua"
MODS="ServerEventManager${1:+;$1}"
if [ -n "$SEM_ALIFE" ]; then  # SEM_ALIFE=1: also load A-Life + Jimmy from the Workshop folder (copied, not linked)
  WS="/d/SteamLibrary/steamapps/workshop/content/108600"
  for m in 3803984183/mods/ProjectALifeNPCs 3806944055/mods/ProjectALifeJimmy; do
    [ -d "$CACHE/mods/$(basename "$m")" ] || cp -r "$WS/$m" "$CACHE/mods/"
  done
  MODS="$MODS;ProjectALifeNPCs;ProjectALifeJimmy"
fi
if [ -f "$CACHE/Server/SEMTest.ini" ]; then
  sed -i "s/^Mods=.*/Mods=$MODS/" "$CACHE/Server/SEMTest.ini"
else
  printf 'Mods=%s\nOpen=true\nPublic=false\nPauseEmpty=true\n' "$MODS" > "$CACHE/Server/SEMTest.ini"
fi
# the minimap is off by default; the rig needs it to test event markers there
[ -f "$CACHE/Server/SEMTest_SandboxVars.lua" ] && sed -i 's/AllowMiniMap = false/AllowMiniMap = true/' "$CACHE/Server/SEMTest_SandboxVars.lua"
W_HOME="$(cygpath -w "$HOME_DIR")"
cd "$GAME"
exec ./jre64/bin/java.exe --enable-native-access=ALL-UNNAMED \
  --add-exports=java.base/jdk.internal.misc=ALL-UNNAMED \
  -XX:+UseZGC -XX:-CreateCoredumpOnCrash -XX:-OmitStackTraceInFastThrow -Xmx3072m \
  "-Duser.home=$W_HOME" "-Ddeployment.user.cachedir=$W_HOME\Zomboid" \
  "-Djava.library.path=./natives/;./natives/win64/;./" \
  -cp "./;projectzomboid.jar" zombie.network.GameServer \
  -nosteam "-cachedir=$W_HOME\Zomboid" -servername SEMTest -adminpassword semtest </dev/null
