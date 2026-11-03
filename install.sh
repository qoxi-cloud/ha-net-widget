#!/bin/zsh
# Build, copy to ~/Applications and (re)start via a per-user LaunchAgent.
#   HA_URL=http://<ha>:8123 [HA_CLOUD_URL=https://<id>.ui.nabu.casa] ./install.sh
# URLs are remembered (defaults domain cloud.qoxi.netwidget), later runs need no env.
# ./install.sh --uninstall removes the app and the agent (Keychain item stays).
set -euo pipefail
cd "${0:A:h}"
LABEL=cloud.qoxi.netwidget
DEST=~/Applications/NetWidget.app
PLIST=~/Library/LaunchAgents/$LABEL.plist
DOMAIN=gui/$(id -u)

launchctl bootout $DOMAIN/$LABEL 2>/dev/null || true
if [[ ${1:-} == --uninstall ]]; then
  rm -rf $DEST $PLIST
  echo "removed; token: security delete-generic-password -s $LABEL -a ha"
  exit 0
fi

[[ -n ${HA_URL:-} ]] && defaults write $LABEL haURL "$HA_URL"
[[ -n ${HA_CLOUD_URL:-} ]] && defaults write $LABEL haCloudURL "$HA_CLOUD_URL"
if ! defaults read $LABEL haURL >/dev/null 2>&1; then
  echo "set HA_URL=http://<ha>:8123 (optionally HA_CLOUD_URL) on the first run" >&2
  exit 1
fi

./build.sh
mkdir -p ~/Applications ~/Library/LaunchAgents
rm -rf $DEST
cp -R build/NetWidget.app $DEST
cat > $PLIST <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$DEST/Contents/MacOS/NetWidget</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<!-- restart after a crash, but "Quit NetWidget" (exit 0) stays quit until next login -->
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
</dict>
</plist>
PL
launchctl bootstrap $DOMAIN $PLIST
echo "running: $(launchctl print $DOMAIN/$LABEL | grep -E '^\s+(state|pid) =' | xargs)"
