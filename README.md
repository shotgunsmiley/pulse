# Pulse Network v3.3 — controlled tester package

This package contains the current Kivy Android client and its matching Python standard-library server.

## Package contents

- `main.py` — single-file Kivy Android client.
- `server.py` — single-file server for Render.
- `buildozer.spec` — Android APK build configuration.
- `requirements.txt` — server dependency note; the server uses Python standard-library modules only.
- `simulation_test.py` — repeatable local HTTP simulation using three independent device identities.
- `SIMULATION_REPORT.md` — automated simulation results and limitations.
- `MANUAL_ANDROID_TEST.md` — required physical-device checks, including UI responsiveness and backup/restore.
- `slow_test_server.py` — local-only Termux stub that delays the first lobby history response for 18 seconds to test the 15-second client timeout.

## Product and network terminology

Pulse Network is the product name. Technically, this version is a **server-hosted game with a device-presence registry**. The Render server is the coordinator. The app's “devices” screen lists app instances that have recently checked in. Phones do not directly connect to each other, relay traffic, validate blocks for one another, run consensus, or maintain a decentralized ledger. The mining work challenge is verified by the central server; it is not a blockchain.

## Game and account scope

- PLS is an in-app game balance only. There are no deposits, withdrawals, cash-outs, exchanges, or player-to-player stakes.
- Duel is solo skill practice. Multiplayer PvP, series, rematches, duel chat, rivals, and leaderboards are not implemented in this client/server source.
- Gear durability values remain in stored recipe/gear data, but durability is not consumed. The UI no longer claims gear has a specific number of uses.
- The old title palette has been removed from the client. Some legacy title/win/loss fields remain in the JSON user records but are dormant; no title progression is currently awarded.
- Player tags are random four-digit tags. A collision-retry and one-time migration strategy for already duplicated tags has not yet been implemented. At small tester counts the risk is low, but do not assume existing tags are globally unique.

## Public lobby notice

Lobby history is intentionally public in this version: it can be read without a registered node. Testers should not post private, identifying, or sensitive information in the lobby. Private DMs and account data require node authentication and wallet ownership checks.

## Client network behavior

- UI network operations use `api_async(method, path, data, on_done)`. HTTP runs on a daemon thread; callbacks are scheduled through Kivy's `Clock` so widget updates occur on the UI thread.
- The mine work difficulty is fetched from `/health` after node registration. If the health response is missing or malformed, the client falls back to difficulty `2`.
- The client HTTP timeout is 15 seconds. Automated source checks confirm the named UI actions use the asynchronous helper, but only the manual Android test can confirm responsiveness on a real phone.
- The five-second mine cooldown is enforced per wallet by the server. It slows repeated mining by one wallet; it does **not** prevent Sybil abuse through multiple wallets.

## Wallet backup and recovery

Open **Wallet → Export Secure Backup**. Android's system save-location picker asks where to save a ZIP containing `pulse_wallet.json` and `pulse_node.json`. This is a user-selected file export, not a clipboard copy or a secret displayed on screen. Keep the ZIP private: it contains the wallet secret and node credential.

To recover, choose **Wallet → Restore From Backup**, select that ZIP, and let the app validate it. The app restores the wallet ID and secret, generates a fresh device/node identity, and asks you to fully close and reopen Pulse Network. After reopening, it registers the restored wallet with the new node identity. The live Android picker and restore path still require the manual device test; they have not been executed in this environment.

The wallet secret is a prototype account credential, not a hardware-backed key. Do not send the backup to support, post it, or share it with testers. Android Keystore protection is deferred.

## Deploying the server to Render

1. In the GitHub repository connected to `https://pulse-nadr.onrender.com`, replace the deployed server file with this package's `server.py`.
2. Set the Render **Start Command** to `python server.py`.
3. Deploy and wait for the service to become Live.
4. Open `https://pulse-nadr.onrender.com/health`. It should return `ok: true`, `version: 3.3`, and the configured mining `difficulty`.
5. For account persistence, configure a Render persistent disk and set `PULSE_DATA_FILE` to a path on that disk, for example `/var/data/pulse_data.json`. Without persistent storage, JSON data can be lost after restarts or redeploys. Do not overwrite or delete existing player data if you need to preserve tester accounts.

`PULSE_MINE_COOLDOWN` defaults to five seconds. It is configurable for local simulation only; do not set it to zero on the live service. `PULSE_DIFFICULTY` defaults to `2`; clients read the active value from `/health`.

## Building the Android APK in Google Colab

1. Upload `main.py` and `buildozer.spec` into the same Colab working folder.
2. Install Buildozer and its Android build dependencies using your normal Colab setup.
3. Run:

   ```bash
   buildozer android debug
   ```

4. Download the generated APK from `bin/` and install it on the test phone.

The client points to `https://pulse-nadr.onrender.com`. Deploy the matching server before installing this client because mutations require a successful node handshake.

## Automated verification

Run from the package directory:

```bash
python simulation_test.py
```

The simulation creates a temporary JSON database and starts a local server. It does not contact or modify the live Render service. It tests three simulated devices, registration, discovery, authentication boundaries, private DMs, cooldown behavior, mining replay protection, quest claims, forging, restart persistence, and offline-node expiry. It also performs source-level checks for asynchronous UI methods, difficulty negotiation, and backup/restore code presence.

The simulation temporarily sets `PULSE_MINE_COOLDOWN=0` only after verifying the five-second default, so bulk mining tests do not wait five seconds for every proof. This is confined to the child server process launched by the test script.

## Not yet verified / known limitations

- Kivy has not been launched in an Android runtime here, and no APK has been built or installed.
- The Android save-location picker and ZIP restore callback have not been run on a physical phone. Complete `MANUAL_ANDROID_TEST.md` before inviting external testers.
- The local simulation is not a real two-phone test and does not prove Render deployment, Android lifecycle behavior, network handoff, or UI responsiveness during a real 15-second timeout.
- The backend stores JSON on disk. It is suitable for a small, controlled test, not a public launch. It needs persistent storage, backups, stronger identity controls, and operational monitoring before broader release.
- Five-second cooldown is per wallet only and is not a proof-of-humanity or Sybil defense.
- Existing duplicate player tags, if any, are not migrated in this version.
