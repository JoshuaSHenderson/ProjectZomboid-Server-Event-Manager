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
# Workshop mods copied fresh every boot (not linked), so the rig never runs an older copy than Steam has. On by default, as on
# the live server: SEM_ALIFE=0 drops A-Life and its Jeem Extension (ProjectALifeJimmy); SEM_VIEWPOINT=0 drops ZombieBuddy and
# Viewpoint (first-person view; a client Java mod, so tools/test-client.sh starts the ZombieBuddy agent).
WS="/d/SteamLibrary/steamapps/workshop/content/108600"
EXTRA=""
[ "${SEM_VIEWPOINT:-1}" != 0 ] && EXTRA="$EXTRA 3619862853/mods/ZombieBuddy 3809306528/mods/Viewpoint"
[ "${SEM_ALIFE:-1}" != 0 ] && EXTRA="$EXTRA 3803984183/mods/ProjectALifeNPCs 3806944055/mods/ProjectALifeJimmy"
for m in $EXTRA; do
  [ -d "$WS/$m" ] || { echo "missing Workshop mod $WS/$m: subscribe in Steam, or turn it off (SEM_ALIFE=0 / SEM_VIEWPOINT=0)" >&2; exit 1; }
  rm -rf "$CACHE/mods/$(basename "$m")"
  cp -r "$WS/$m" "$CACHE/mods/"
  MODS="$MODS;$(basename "$m")"
done
echo "Mods=$MODS"
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
