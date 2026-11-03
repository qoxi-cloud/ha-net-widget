# NetWidget

Desktop-level glass panel for macOS 26 with the three ISPs of the Ghost site:
one row per provider = OmadaBridge WAN link + 8311 ONU stick + CRS305 port
throughput. Live over the HA websocket (`subscribe_entities`, ~30 entities),
no WidgetKit refresh budget. LAN first (4 s handshake deadline), then Nabu Casa;
on the cloud it probes the LAN every 60 s and moves back (cloud icon in the header).
Width 344 = two macOS small widgets + gap, so it lines up under them.

Discovery mirrors the qoxi Mushroom ISP/ONU cards: `sensor.<gw>_wan_latency_port_<n>_<slug>`
→ WAN link; ONU = `sensor.8311_onu_<serial>_*` whose name contains the ISP token
(`LinkCom_sfp2` → `linkcom`); throughput = sensors named `<ISP> download/upload`.

## Build / install (Command Line Tools only, no Xcode)

    HA_URL=http://<ha>:8123 HA_CLOUD_URL=https://<id>.ui.nabu.casa ./install.sh
    ./install.sh              # later runs: URLs are remembered
    ./install.sh --uninstall

Builds `~/Applications/NetWidget.app` and the LaunchAgent `cloud.qoxi.netwidget`.
`HA_CLOUD_URL` is optional (LAN only without it).

Debug: `build/NetWidget.app/Contents/MacOS/NetWidget --watch` (prints changes),
`--snapshot out.png` (renders once with live data).

## Token

HA user `netwidget` (non-admin; not local-only when a cloud URL is used), long-lived
token in the login Keychain (service `cloud.qoxi.netwidget`, account `ha`). Created by
`HA_URL=… [HA_CLOUD_URL=…] HA_MCP_URL=… ./make_token.py` (HA_MCP_URL = an ha-mcp
endpoint with admin rights, used to create the user); re-run after deleting the user in HA. Without ha-mcp: create a
non-admin user in HA, log in as it, make a long-lived token under Profile → Security and
`security add-generic-password -s cloud.qoxi.netwidget -a ha -w`.

Change URLs: `defaults write cloud.qoxi.netwidget haURL|haCloudURL <url>` and restart
(or `-haURL <url>` on the command line for a one-off run).

## Use

Drag anywhere to move (position is remembered). Right click: Reconnect,
Open Network dashboard, Quit.

Starts by itself at login (LaunchAgent, `RunAtLoad`) and is restarted after a crash;
"Quit" stays quit until the next login. By hand:

    launchctl kickstart gui/$(id -u)/cloud.qoxi.netwidget        # start
    launchctl kill TERM gui/$(id -u)/cloud.qoxi.netwidget        # stop until next login
    launchctl kickstart -k gui/$(id -u)/cloud.qoxi.netwidget     # restart

If it doesn't come up after a reboot, check System Settings → General → Login Items &
Extensions → Allow in the Background (macOS lists the agent there; switching it off
disables autostart).
