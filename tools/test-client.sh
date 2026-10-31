#!/usr/bin/env bash
# Launches one isolated game client. Usage: tools/test-client.sh N   (N = 1 or 2)
# user.home is .testclient<N>, never the real ~/Zomboid. Run the test server first (tools/test-server.sh).
set -e
[ -d ServerEventManager/Contents ] || { echo "run from repo root" >&2; exit 1; }
case "$1" in 1|2) N="$1";; *) echo "usage: $0 1|2" >&2; exit 1;; esac
ROOT="/s/ProjectZomboid-Server-Event-Manager"
HOME_DIR="$ROOT/.testclient$N"
GAME="/d/SteamLibrary/steamapps/common/ProjectZomboid"
mkdir -p "$HOME_DIR/Zomboid/mods"
rm -rf "$HOME_DIR/Zomboid/mods"/*
cp -r "${SEM_HOME:-$ROOT/.testserver}/Zomboid/mods"/* "$HOME_DIR/Zomboid/mods/"
W_HOME="$(cygpath -w "$HOME_DIR")"
echo "Join: IP 127.0.0.1  port 16261  $( [ "$N" = 1 ] && echo 'user admin / password semtest' || echo 'any other username, any password' )"
cd "$GAME"
# flags from ProjectZomboid64.json (agentlib:zbNative and steam flag dropped: -nosteam)
exec ./jre64/bin/java.exe --enable-native-access=ALL-UNNAMED \
  --add-exports=java.base/jdk.internal.misc=ALL-UNNAMED \
  -XX:+UseG1GC -XX:-CreateCoredumpOnCrash -XX:-OmitStackTraceInFastThrow -Xmx4096m \
  "-Duser.home=$W_HOME" "-Ddeployment.user.cachedir=$W_HOME\Zomboid" \
  "-Djava.library.path=win64/;." \
  -cp ".;projectzomboid.jar" zombie.gameStates.MainScreenState \
  -nosteam "-cachedir=$W_HOME\Zomboid" </dev/null
