---
name: wireless-debugging
description: >
  Set up Android wireless debugging for Flutter (adb pair with pairing code,
  adb connect, flutter devices, flutter run on a physical phone over Wi-Fi or
  Tailscale). Use when the user says wireless debugging, pair my phone,
  connect my phone, run on device, adb pair, pairing code, or test on mobile.
---

# Wireless debugging (Flutter + adb)

## Environment quirks (this machine)

- `flutter` is NOT on PATH: use `~/flutter/bin/flutter`.
- `adb` is NOT on PATH: use `~/Android/Sdk/platform-tools/adb`
  (or export it into PATH per command).
- `flutter doctor` reports no JDK until `JAVA_HOME` points at a JDK 17, e.g.
  `export JAVA_HOME=~/tooling/jdk-17.0.11+9`. `flutter run` on Android needs it.
- Tailscale IPs (`100.x`) work fine for both pairing and connecting.

## Pairing flow

1. Phone and PC on the same Wi-Fi (Tailscale alone also works).
2. Phone: Developer options → Wireless debugging ON → "Pair device with
   pairing code". It shows an `IP:PORT` plus a 6-digit code.
3. Ask the user for IP, port, and code as THREE separate answers — users mash
   `IP:PORT` into one string (e.g. `192.168.0.23342331` is really
   `192.168.0.233:42331`). Never guess the split silently.
4. Pair non-interactively, code as argument:
   `adb pair <IP>:<PORT> <CODE>`
   Do NOT pipe via `echo <code> | adb pair ...` — that fails with
   `protocol fault (couldn't read status message)`.
5. On ANY pair failure (`protocol fault`, auth errors): the code probably
   expired (they live ~2 min). Have the user re-tap "Pair device with pairing
   code" and retry with the fresh triplet. `adb kill-server; adb start-server`
   first if failures persist.
6. Pairing port ≠ connect port. After pairing, adb usually auto-connects (device
   appears as `adb-XXXX._adb-tls-connect._tcp` in `adb devices`). A manual
   `adb connect <main-IP>:<main-port>` may say "failed to connect" when it's
   already connected — always check `adb devices -l` before concluding failure.
7. Verify: `flutter devices` should list the phone as `(wireless)`.

## Running the app

- First `flutter run -d <device-id>` triggers a full Gradle `assembleDebug`
  (5–15 min with heavy plugins). Reloads after that are ~1s.
- NEVER launch it with `&`/`nohup` under a tool call: the tool timeout kills
  the whole process group, including the "backgrounded" build. Use tmux:
  `tmux new-session -d -s fish -c <repo> '<env exports>; ~/flutter/bin/flutter run -d <id>'`
  Poll with `tmux capture-pane -p -t fish | tail`. The user attaches
  (`tmux attach -t fish`) for interactive hot-reload keys (`r`/`R`/`q`).

## Low-RAM machines (11 GB or less)

- Check `free -h` first. If swap is full and the box is thrashing, the
  culprits are Gradle (`-Xmx` up to several GB) and KotlinCompileDaemon
  (observed `-Xmx8G`!). Cap BEFORE building in `~/.gradle/gradle.properties`:
  `org.gradle.jvmargs=-Xmx2g`, `org.gradle.workers.max=2`,
  `kotlin.daemon.jvmargs=-Xmx1g`.
- Emergency throttle without killing: `renice -n 15 -p <pid>` + `ionice -c3`.
- NEVER `pkill -f <pattern>`: the pattern string appears in your own shell's
  cmdline, so pkill kills your own command (no output, tool timeout). Kill by
  exact PID, or use the bracket trick (`'GradleWrapperMai[n]'`) which can't
  self-match.
- Watch for stale `opencode` sessions holding GBs of RAM/CPU; ask the user
  before touching other sessions' processes.
