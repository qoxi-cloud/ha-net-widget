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

Debug (`build/NetWidget.app/Contents/MacOS/NetWidget …`): `--watch` prints changes;
`--snapshot out.png [--detail <isp>:<rx_power|tx_power|optic_temperature|latency|rates|status>:<1h|24h|7d> [--hover 0.5]]`
renders the widget or a detail panel once with live data; `--click x,y` clicks the real
window at widget coordinates and prints the hit map (stop the LaunchAgent first).

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

Click (no drag) opens a detail panel beside the widget, like HA's more-info:
- RX / TX / Optic / Latency tile → history chart: 1h raw states (step line), 24h 5-minute
  and 7d hourly statistics (mean line + min/max band); thresholds drawn when in range,
  otherwise the footer gives the margin to the warning level
- ↓/↑ → download and upload on one chart
- provider name → WAN / PON status timeline with uptime and outages

Hover shows the value under the cursor; Esc or a click elsewhere closes it; "Open in HA"
opens the entity history in HA. Data is fetched on open (and every 30 s while open) over
the same websocket, so it works via the cloud too.

Starts by itself at login (LaunchAgent, `RunAtLoad`) and is restarted after a crash;
"Quit" stays quit until the next login. By hand:

    launchctl kickstart -k gui/$(id -u)/cloud.qoxi.netwidget     # (re)start, also after "Quit"
    launchctl bootout gui/$(id -u)/cloud.qoxi.netwidget          # stop until next login
    launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/cloud.qoxi.netwidget.plist  # start after bootout

A plain `kill` doesn't stop it: launchd restarts anything that didn't exit cleanly.

If it doesn't come up after a reboot, check System Settings → General → Login Items &
Extensions → Allow in the Background (macOS lists the agent there; switching it off
disables autostart).
