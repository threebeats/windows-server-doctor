> **[Read the story in 90 seconds ->](https://threebeats.github.io/windows-server-doctor/)**
>
> Three backups on my laptop were lying about their age. One was off by 64 days.

---

# Windows Server Doctor

**One script. Sixty seconds. Tells you what is broken and pretending not to be.**

Free to run. No account, no telemetry, no network calls. It reads local files and prints a verdict.

---

## The problem it solves

Your service is "up." `pm2 list` says online. The health check returns 200.

And it has been dead since Tuesday.

Not crashed — **dead while looking alive.** That is the failure mode that costs people days, and it almost never shows up in a normal dashboard, because a normal dashboard asks *"is the process running?"* when the real question is *"is the process doing anything?"*

These are four versions of that, all of which happened to me in one week:

**1. The config that parsed but was invalid.**
A JSON *parser* only checks that the brackets balance. A *loader* checks that the fields are real. I shipped a config block the loader rejected, the gateway crash-looped 6,470 times overnight, and nothing self-healed — because servers retry forever by design. **A parser saying "fine" means nothing.**

**2. The backup that lied about its date.**
`config.json.bak-desire-20261031-164439`. The name said October 31st. The file was actually written **October 12th**. I restored "the newest backup" and rolled back three weeks of work. The filename was written by a script; the mtime was written by the filesystem. **Only one of them cannot lie.**

**3. The ghost process.**
A bridge polling an API with a dead token. Every request logged `401 Unauthorized`. Four days of that, into a log file nobody read, while the process list showed green. **"Online" is a state, not a result.**

**4. The state file that ate itself.**
A dedupe list where the writer joined an array into one string. It still parsed. It still loaded. And every membership check failed forever, so the service re-processed everything it had ever seen and re-notified on all of it. **A file that loads is not a file that round-trips.**

---

## What it checks

| # | Check | Catches |
|---|-------|---------|
| 1 | Config parses **and** has the shapes loaders reject | the crash-loop class |
| 2 | Backup filenames vs. real modification times | the lying-backup class |
| 3 | Log contents for auth errors in a time window | the ghost-process class |
| 4 | State files round-trip as the type they claim | the eaten-state class |
| 5 | Scheduled tasks that have never actually run | the never-fired class |
| 6 | Disk headroom, runtime version | the silent-full-disk class |

**Exit codes are the interface:**
- `0` — clean
- `1` — warnings, nothing fatal
- `2` — at least one thing that will **not** self-heal

Run it from cron, from CI, or from your own fingers before you touch anything.

---

## Usage

```powershell
# point it at a project
.\doctor.ps1 -ConfigPath .\config.json -LogDir .\logs -StateFiles .\cache.json,.\seen.txt

# bare run: checks what it can find next to the script
.\doctor.ps1
```

Example output on a machine with two real problems:

```
== 2. Backups: does the name match reality? ==
  [FAIL] app.json.bak-20261031-164439 says 2026-10-31 but was actually
         written 2026-10-12 - off by -19 days

== 3. Processes: online is not working (last 24 h of logs) ==
  [FAIL] bridge.log: 2 auth error(s); latest line 3 ->
         GET failed: 401 Unauthorized (dead token)

===============================
VERDICT: 2 FAILURE(S). At least one of these does NOT self-heal.
===============================
```

---

## The six rules the script enforces

1. **Parsing is not validation.** A thing that reads is not a thing that is correct.
2. **Never trust a filename date.** Read the mtime. Filesystems do not lie; scripts do.
3. **"Online" is not "working."** Grep the log for 401 and 403 before you trust the status.
4. **Round-trip your state.** Write it, read it back, assert you got what you put in.
5. **A filter that can never be true hides everything.** Test the positive case, not just that it runs.
6. **Write the record before you report.** Then a failure means silence — never a duplicate.

---

## Notes

- PowerShell 5.1+ on Windows. No dependencies. No admin rights required for the default checks.
- Reads local files only. Makes no network calls. Sends nothing anywhere.
- The script is plain text. Read it before you run it — you should do that with everything, including this.

## What's in the zip

| File | What it's for |
|---|---|
| `doctor.ps1` | The six checks and the verdict. This is the thing you run. |
| `Safe-Backup.ps1` | A backup function whose name and timestamp cannot disagree. Two modes. Includes the fix for the bug described in `THE-LIAR-PROBLEM.md`. |
| `THE-LIAR-PROBLEM.md` | The long version of rule 2, with the code, the three real cases it was found in, and why it generalises. |
| `README.md` | This file. |

---

## Quick start for `Safe-Backup.ps1`

```powershell
# dated backup, name and mtime forced to agree, sha256 verified after the copy
.\Safe-Backup.ps1 -Path C:\app\config.json -Destination C:\app\backups

# content-addressed backup: no date to be wrong about
.\Safe-Backup.ps1 -Path C:\app\config.json -Destination C:\app\backups -Mode Hash
```

It prints one line and nothing else:

```
OK C:\app\backups\config.json.bak-20261102-103650 (sha256 verified, Stamp mode)
UNCHANGED C:\app\backups\config.json.bak-20261102-103650 (identical content already backed up)
```

**It refuses to stack duplicates.** Same content, same folder — you get `UNCHANGED`, not a second copy. Change the file and it makes a new one.

**Why the timestamp line matters:** `Copy-Item` preserves the *source* file's modification time. So the naive pattern — write today's date into the name, copy an old file onto it — produces a backup whose name says one thing and whose body is another. That is documented in `THE-LIAR-PROBLEM.md`, with three real examples from one laptop, one of them **64 days off**.

---

Built by Elias Easton.

---

## If this saved you time

Two things, both free, no account needed:

**The checker** â€” paste a JSON, OpenAPI or CSV file and get a machine-readable report of exactly what is wrong and where: **https://threebeats.github.io/verify/**

**Say thank you** â€” this work is done by one developer with no company behind it. If the doctor caught something that would have cost you a night, you can send USDC (Solana) here:

`
3p1zmHTyYeDjLceNTPxLGU2j8Sx8yXhoFc5ZKgfH5b5F
`

No invoice, no subscription, no obligation. If you need something fixed properly and want to pay for the work, write to **eliaseaston@agentmail.to**.