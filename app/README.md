# Pulse Network v4

A 3D mining and wagering game for Android. You mine **PLS** (Pulse) by playing, then stake it in skill duels, tournaments and luck games.

**PLS can only come from playing.** New PLS is only created by your phone acting as a network node while you mine, plus a one-time starter grant for new players. In v4 it cannot be bought, sold, sent to another player or cashed out. The long-term goal is a licensed real-money version if state laws allow it, but nothing in v4 moves real money.

---

## Contents
1. What's in the download
2. The game: Town, Mine, Forge, Arena, Gambit Hall, Tavern, Notice Board, Profile
3. The PLS economy
4. Fairness and anti-cheat
5. How it's built
6. Setup: server, phone build, APK
7. Testing
8. Known limits
9. Ideas for later
10. Version history

---

## 1. What's in the download

| File | What it is |
|---|---|
| `pulse_v4.zip` | The Godot 4 app (the game itself) |
| `pulse_phase0.zip` | A tiny test app that checks the phone build works (spinning crystal, server check, vibration test) |
| `server.py` | The game server (runs on Render) |
| `requirements.txt` | Server packages (`psycopg2-binary`, only used with Postgres) |
| `SETUP_V4.md` | Short setup steps |
| `PULSE_V4_DESIGN.md` | Design notes, wagering categories and 30 future ideas |
| `test_server_v4.py`, `test_app_contract.py` | Server tests |

### Inside `pulse_v4.zip`
```
pulse_v4/
  project.godot        Godot settings (720x1280 portrait, Compatibility renderer)
  main.tscn            The one scene the app starts in
  icon.png             App icon
  icons/               17 pixel-art icons
  sounds/              18 sound effects
  scripts/
    main.gd            App controller: login state, top bar, bottom tabs, panels, sound, vibration
    api.gd             Talks to the server (HTTP + JSON, saved session)
    ui.gd              Shared look: colours, buttons, cards, number formatting
    world.gd           3D world: town and mine, lights, camera, tapping places/veins
    hero.gd            Your 3D adventurer: walking, swinging, appearance
    mesh_builder.gd    Turns the model data into 3D meshes
    model_data.gd      All 3D models and map layouts (generated, do not hand-edit)
    screens/
      login.gd         Sign in / create account / server settings
      mine_panel.gd    Mining strike bar and vein picker
      forge.gd         Make, repair and upgrade gear
      arena.gd         Skill games: practice, duels, tournaments
      hall.gd          Luck games: Flip, Dice, Cave-In, fairness check
      tavern.gd        Chat: lobby, crew, friends
      board.gd         Quests, leaderboards, economy
      profile.gd       Look, shop, stats, settings
    games/
      skill_game.gd    Quickdraw, Rune Sequence and Vein Sniper
```

---

## 2. The game

You walk a blocky adventurer around a small 3D world, with the camera behind them. Tap a building in town to walk there, or use the tabs along the bottom: **Town, Mine, Forge, Arena, Hall, Tavern, Board**. The top bar shows your PLS, your four ores, your level and title, and an XP bar. Tap **ME** to open your profile.

New accounts start with **25 PLS** (the welcome bonus).

### Town
An open plaza with the glowing Pulse crystal monument in the middle. Around it are the Mine entrance, the Forge, the Arena, the Gambit Hall, the Tavern and the Notice Board, with lamp posts, pine trees and rocks.

### Mine (the Deep Veins)
A lamp-lit cavern with four veins. Mining is **pure skill**: no random ore rolls.

1. Pick a vein. Your adventurer walks to it.
2. A marker slides across a bar with a gold zone.
3. Tap **STRIKE** when the marker is in the gold.

| Hit | Damage | Ore | XP |
|---|---|---|---|
| Perfect | 6 | 3 | 4 |
| Great | 4 | 2 | 3 |
| Good | 2 | 1 | 1 |
| Miss | 0 | 0 | 0 |

When a vein's HP reaches zero it's **cleared** and pays PLS:

| Vein | Ore | HP | PLS when cleared | Needs |
|---|---|---|---|---|
| Coal Seam | Coal | 12 | 10 | Level 1 |
| Iron Vein | Iron | 18 | 18 | Level 3 |
| Pulse Crystal Grotto | Crystal | 26 | 30 | Level 8 + Iron pickaxe |
| Void Rift | Void | 36 | 50 | Level 15 + Crystal pickaxe |

Deeper veins have a faster marker and a smaller gold zone. Vein rewards shrink after a lot of mining in one day: half after 30 veins and a quarter after 60. This keeps PLS from flooding the game.

**Levels and titles:** Pebble Picker (1), Tunnel Rat (3), Ore Hound (6), Vein Seeker (10), Deep Delver (15), Crystal Warden (20), Void Walker (30).

### Forge
Make gear from ore plus PLS. **Gear only helps mining. It never helps in the Arena.**

| Slot | Effect |
|---|---|
| Pickaxe | More damage per strike |
| Gauntlets | Wider strike zone |
| Visor | Slower strike marker |

| Tier | Ore cost | PLS cost | Durability |
|---|---|---|---|
| Iron | 12 iron + 8 coal | 40 | 150 |
| Crystal | 12 crystal + 10 iron | 120 | 300 |
| Void | 10 void + 12 crystal | 300 | 600 |

Gear wears down as you mine. A broken pickaxe stops helping until it's repaired. Repairs cost PLS (more for higher tiers). Gear can be upgraded up to **3 stars**.

### Arena: skill wagering
Pure skill: both players get the **exact same challenge**, and gear does nothing. The server creates every challenge and scores every run.

| Game | Type | How it plays |
|---|---|---|
| **Quickdraw** | Reaction | 5 rounds. Tap the moment the pad turns green. Early taps score 0. |
| **Rune Sequence** | Memory | Watch the runes light up, then repeat them. One more each round, up to 20. |
| **Vein Sniper** | Precision | 12 veins flash on a 4x4 grid. Hit each before it fades. Faster hits score more. |

Three tabs:
- **Practice**: free, saves your personal best.
- **Duels**: ranked 1v1.
  - **Matchmaking:** pick a game and a stake (0, 10, 25, 50, 100 or 250 PLS) and the server matches you by game, stake and rating.
  - **Direct challenge:** challenge a player by username.
  - **Pot:** both stakes are held safely. The winner takes the pot minus 5%, and that 5% is burned (deleted forever). A draw refunds both players.
  - **Async play:** you don't have to play at the same time.
  - **Forfeits:** leaving or restarting a duel counts as a forfeit.
- **Tourneys**: a weekly cup for each game.
  - **Entry and attempts:** 50 PLS entry, 5 attempts, best score counts.
  - **Burn:** 10% of all entries is burned.
  - **Payout:** the rest goes 50% / 30% / 20% to the top three.

**Ranks** follow your rating (everyone starts at 1200): Bronze, Silver (1100), Gold (1250), Platinum (1400), Diamond (1550). Ratings drift back toward the middle each month (seasons).

### Gambit Hall: luck wagering
House-banked games with a **3% house edge** (about 97% paid back over time). Bets are 1 to 500 PLS.

| Game | How it plays | Pays |
|---|---|---|
| **Crystal Flip** | Call teal or amber | 1.94x |
| **Ore Dice** | Roll 0.00 to 99.99, win if under your target (2 to 95) | 97 / target (target 50 pays 1.94x) |
| **Cave-In** | 5x5 field with 1 to 10 hidden cave-ins. Each safe tile raises the multiplier. Cash out any time, or lose the bet on a cave-in | Grows per tile |

The **Fair** tab lets you check every result yourself (see section 4).

### Tavern
- **Lobby**: public chat for everyone.
- **Crew**: create a crew for 300 PLS (up to 20 members). Crews get private chat and a weekly crew board.
- **Friends**: add friends and see who's online.

### Notice Board
- **Quests**: five daily quests that reset at midnight UTC.

| Quest | Goal | Reward |
|---|---|---|
| Land 25 Strikes | Good or better hits | 30 PLS + 10 coal |
| Clear 4 Veins | Break veins | 40 PLS + 6 iron |
| Play 3 Skill Games | Practice, duels or cups | 30 PLS + 3 crystal |
| Win a Duel | Beat a player | 50 PLS + 1 void |
| Visit the Smith | Forge, upgrade or repair | 25 PLS + 4 iron |

- **Leaders**: most veins cleared this week, highest XP, and top Arena rating for each skill game.
- **Economy**: total PLS mined, total burned, how much players hold, how much is locked in duels and cup pots, whether the ledger balances, and your last PLS transactions.

### Profile (ME)
- **Look**: change skin, hair style, hair colour, tunic, trousers and trim. Your 3D adventurer updates right away.
- **Shop**: buy cosmetic styles with PLS, for example Braided Crest (80), Pulse Teal Hair (150), Void Cloak (400), Void Trim (250). Cosmetics never affect gameplay.
- **Stats**: your mining, Arena and luck history.
- **Settings**: sound, vibration, server address, log out.

---

## 3. The PLS economy

**Where PLS comes from:** clearing veins, daily quests and the 25 PLS welcome bonus. Nothing else.

**Where PLS leaves the game (sinks):**
- Forging, repairing and upgrading gear
- The cosmetic shop
- Creating a crew
- 5% of every duel pot (burned)
- 10% of every cup entry (burned)
- The 3% house edge in the Gambit Hall

**The ledger:** every PLS movement is recorded twice, once leaving one account and once arriving in another. The system accounts are *mint* (new PLS), *burn* (destroyed PLS), *house* (luck games), *escrow* (duel stakes) and *pots* (cup prize pools). Together with all players, the total always equals exactly zero. If it ever didn't, PLS would have been created or lost by a bug. The Economy tab shows "Ledger balanced: YES".

**Why the limits:** play-to-earn games like Axie and StepN collapsed because they printed currency faster than players spent it. Pulse caps mining with the daily slowdown and spends PLS through the sinks above.

---

## 4. Fairness and anti-cheat

**Provably fair luck games**
1. Before you bet, the server picks a secret seed and shows you its fingerprint (a SHA-256 hash).
2. Each result comes from HMAC-SHA256(secret seed, your seed : bet number).
3. Tap **Reveal + New Seeds** to see the old secret. The app recomputes every result and confirms the server couldn't have changed them.
4. You can type in your own seed.

Fractional payouts are carried forward ("dust") instead of being rounded down, so rounding never adds hidden house edge. A test of 20,000 bets came out at about 97% paid back.

**Server-controlled skill**
- The server makes every mining challenge and skill-game challenge, and scores them itself.
- It rejects impossible results, such as reaction times faster than a human can tap.
- 37 or more perfect strikes out of the last 40 flags the account as a possible bot and caps its strikes at "good".
- Login attempts are rate-limited.

---

## 5. How it's built

| Part | Technology |
|---|---|
| App | Godot 4 (built and tested on 4.7.2), GDScript, Compatibility (OpenGL) renderer, 720x1280 portrait |
| 3D art | Original 2007-era style low-poly models generated in code: smooth-shaded adventurer, rolling blended terrain, leafy trees, slate and thatch roofs, distance haze. Glowing parts like crystals and lamps are unlit |
| 2D art | Original pixel-art icons |
| Sound | 18 generated sound effects |
| Server | Python 3 standard library (no framework), multithreaded |
| Storage | A JSON file by default, or Postgres when `DATABASE_URL` is set |
| Accounts | Username + password (PBKDF2-hashed), 30-day login sessions |

All art is original, inspired by old-school blocky RPG style. Nothing is copied from RuneScape.

### Server routes (for reference)
- **Public:** `/health`, `/economy`, `/recipes`, `/shop`, `/leaderboard`, `/chat/history`, `/auth/register`, `/auth/login`
- **Logged in, mining and gear:** `/me`, `/heartbeat`, `/mine/veins`, `/mine/start`, `/mine/strike`, `/forge`, `/repair`, `/upgrade`
- **Logged in, quests and history:** `/quests`, `/quests/claim`, `/ledger`
- **Logged in, Arena:**
  - Practice: `/practice/start`, `/practice/submit`
  - Duels: `/pvp/status`, `/pvp/queue`, `/pvp/cancel`, `/pvp/challenge`, `/pvp/respond`, `/pvp/play`, `/pvp/submit`, `/pvp/forfeit`
  - Cups: `/tournaments`, `/tournament/enter`, `/tournament/start`, `/tournament/submit`
- **Logged in, Gambit Hall:** `/luck/flip`, `/luck/dice`, `/luck/cavein`, `/luck/cavein/start`, `/luck/cavein/reveal`, `/luck/cavein/cashout`, `/luck/fair`, `/luck/seed`
- **Logged in, profile and social:** `/profile/appearance`, `/shop/buy`, `/friends`, `/crew`, `/crew/create`, `/crew/join`, `/crew/leave`, plus chat

---

## 6. Setup

### A. Put the server live (Render)
1. In GitHub, replace the old `server.py` and `requirements.txt` with the new ones and commit.
2. Render redeploys on its own. The start command stays `python server.py`.
3. Open `https://pulse-nadr.onrender.com/health`. It should show `"version": 4.0`.
4. Optional, so the free plan stops wiping accounts: create a Postgres database, then add its URL in Render under Environment as `DATABASE_URL`. `/health` will then show `"storage": "postgres"`.
5. Keep the cron-job.org ping on `/health` every 10 minutes so the server stays awake.

The v4 server replaces the v3 one, so the old Kivy app stops working once it's live.

### B. Build the APK on your phone
1. Install **Godot Engine** (4.7) from the Play Store.
2. Unzip `pulse_v4.zip` with the Files app.
3. In Godot, tap **Import**, pick `pulse_v4/project.godot`, then **Import & Edit**.
4. One time only: **Editor > Manage Export Templates > Download and Install** (use Wi-Fi).
5. **Project > Export > Add... > Android**, then set:
   - Use Gradle Build: **off**
   - Architectures: **arm64-v8a** on
   - Unique Name: `org.pulse.pulsev4`
   - Name: `Pulse Network`
   - Permissions: **Internet** and **Vibrate**
6. Tap **Export Project** (keep "Export With Debug" ticked) and save `pulse_v4.apk` to Download.
7. Open it from the Files app to install. Allow "install unknown apps" if Android asks.
8. On first launch, check **SERVER SETTINGS** has your Render address, then create an account.

Try `pulse_phase0.zip` the same way first if you want a quick test of the build steps (Unique Name `org.pulse.phase0`).

**Sharing:** upload the APK to a GitHub Release and share the link.

---

## 7. Testing (done 18 Nov 2026)

| Check | Result |
|---|---|
| Server tests (13 groups, including real HTTP, Postgres path and a 20,000-bet payout test) | 13 / 13 pass |
| App-to-server contract (every field the app reads) | 275 / 275 present |
| Godot 4.7.2 import | Clean |
| Every script compiled in real Godot | 16 / 16 pass |
| Full scripted play-through in real Godot against a live server (20 screens) | 0 errors |

The play-through covered sign-up, the town, mining (perfect strikes, veins cleared), the forge, Arena practice, duels, cups, all four Gambit Hall tabs, Tavern chat, quests, the economy page, the profile look and returning to town.

**Bugs found in real Godot and fixed:**
- Cave-In tiles didn't show as opened.
- The mine was too dark.
- The miner was hidden behind the mining panel.
- The town was washed out by fog.

**Not tested yet:** touch on a real phone, phone speed, and the APK build itself.

---

## 8. Known limits
- Skill games are timed on the phone. The server blocks impossible results and flags streaks, but a modified app could still send believable fake scores. Device integrity checks are a planned fix.
- The free Render plan sleeps when idle and wipes its files. Use Postgres to keep accounts.
- No compliance layer is built (age check, location limits, ID checks, spending limits). It was left out on purpose for v4.
- **For a real-money version later** (this isn't legal advice; get a lawyer before any real money is involved):
  - The luck games would count as online casino gambling, legal in only a few states.
  - Staked duels would be skill gaming, which is decided state by state.
  - Cash-out would need money-transmitter licences.

---

## 9. Ideas for later (30 planned, not built)
- **Staking:** best-of-3 series, double-or-nothing rematch, staked mining duels (Strike-Off), mining races, King of the Hill, score bounties, rating-based stake caps, free duel tickets, live head-to-head, ghost replays.
- **Events:** season payouts, Weekend Deep Dive, Crew Wars, bracket cups, daily featured duel.
- **Luck:** Lucky Lode wheel, Crystal Pot jackpot, High-Low Cart, Ore Drop, weekly Shard Raffle.
- **Economy:** auction house, gear rental, vein claims, pet golem, public audit page.
- **Social:** achievements and titles, login streaks, push notifications, referrals, device integrity checks.

Full descriptions are in `PULSE_V4_DESIGN.md`.

---

## 10. Version history
- **v3.3**: Kivy app with a Python server.
- **v3.4**: Pixel art and crash fixes. Builds through Buildozer on Colab.
- **v3.5**: 10 feature updates.
- **v4.2**: New PLS is only created by phone-node time while mining (plus a one-time 10 PLS starter grant); veins and quests give ore and XP. Optional PULSE test token on Solana devnet: when `PULSE_SOL_SECRET` is set on the server, every node reward is also minted as devnet PULSE (Token-2022) to the player's own Solana wallet. Switch back to the old rules with `PULSE_MINT_POLICY=classic`.
- **v4.1**: Phones act as network nodes while mining: their own signing key, a signed handshake, signed heartbeats every 30 s, hourly node rewards in the internal PULSE ledger (exactly once, capped per hour and per day), node status in Profile > Stats, and an admin audit (needs `PULSE_ADMIN_TOKEN` on Render). PULSE is planned as a Solana Token-2022 token later; see the design plan.
- **v4.0.1**: 2007-era graphics (new adventurer, rolling hills, trees, roofs, lighting) and solid scenery the adventurer walks around.
- **v4.0**: Full rebuild.
  - Godot 4 app in real 3D.
  - Skill mining.
  - Separate skill and luck wagering.
  - Duels, cups and seasons.
  - Provably fair luck games.
  - Double-entry ledger.
  - Real accounts with optional Postgres.
  - Crews and customisation.
