# THE LIAR PROBLEM
## Why every backup tool you have is probably lying to you, and the thirty-line fix

*Elias Easton — Recovery Kit notes, 2026-11-02*

---

## The story, because the story is the point

On the morning of October 31st I made a backup of a config file. My script named it:

```
config.json.bak-desire-20261031-164439
```

Date. Time. Unambiguous. **October 31st, 4:44pm.**

The next morning the config had broken and I needed to roll back fast. I sorted the folder by name, took the newest one, restored it.

**It undid three weeks of work.**

The file's *actual* last-modified time was **October 12th**. The name said October 31st because the script wrote `Get-Date` into the filename — **and then copied an older file onto that name.** The name described *when the copy happened*. The contents were from three weeks earlier. Nothing in the filename, the folder listing, or the sort order told me that.

**The filename lied and I believed it without checking.**

---

## Then I checked a folder I thought was fine

A week later I built a checker and pointed it at my own machine. It found the file above — and while I was cleaning up, it found **two more**, both made by hand, both lying the same way:

| Backup name says | Actually written | Lie |
|---|---|---|
| `bak-desire-20261031-164439` | 2026-10-12 | **19 days** |
| `bak-rebuild-20261101-092409` | 2026-10-31 | 1 day |
| `.env.bak-20261006-074812` | 2026-08-03 | **64 days** |

**Three liars in one folder, on one laptop.** And one of them I made *after* I already knew better, because I used the same pattern: copy a file, stamp it with today's date.

---

## Why this happens to almost everyone

Every backup tool has this shape:

```powershell
$today = Get-Date -Format 'yyyyMMdd-HHmmss'
Copy-Item $file "backups\$file.bak-$today"
```

**`Copy-Item` preserves the source file's modification timestamp.** It does not stamp the copy with "now." It carries the *original's* time along like luggage.

So:
- The **filename** says: *when the backup was taken.*
- The **mtime** says: *when the file being backed up was last changed.*
- If those two things happen to be far apart — restoring an old backup, re-running a script, copying from an archive — **the name and the reality disagree, and the name is the one that looks authoritative.**

You sort by name. You pick the wrong file. You lose days.

---

## The fix, three options

### Option 1 — Touch the timestamp (simplest, do this first)

```powershell
$now = Get-Date
$dest = "backups\$($file.Name).bak-$($now.ToString('yyyyMMdd-HHmmss'))"
Copy-Item $file $dest -Force
(Get-Item $dest).LastWriteTime = $now      # <-- the whole fix
```

Now the name and the mtime are the same fact. **One line.**

### Option 2 — Stop encoding time in the name at all

Name backups by content. A hash can't lie, because it *is* the content:

```powershell
$hash = (Get-FileHash $file -Algorithm SHA256).Hash.Substring(0,16)
$dest = "backups\$($file.Name).$hash.bak"
```

Two files with the same name are identical. Two files with different names are different. **There is no "newest" to get wrong — you just compare.**

### Option 3 — Don't keep backups you can't verify

Before you restore anything, ask it:

```powershell
function Test-BackupHonesty {
  param([string]$Path)
  $m = [regex]::Match((Split-Path $Path -Leaf), '(20\d{6})')
  if (-not $m.Success) { return "no date in name - check manually" }
  $nameDate = [datetime]::ParseExact($m.Groups[1].Value, 'yyyyMMdd', $null)
  $realDate = (Get-Item $Path).LastWriteTime.Date
  $delta = [math]::Round(($realDate - $nameDate).TotalDays)
  if ([math]::Abs($delta) -ge 2) {
    "LIE: name says $($nameDate.ToString('yyyy-MM-dd')), written $($realDate.ToString('yyyy-MM-dd')) - off by $delta days"
  } else {
    "ok - within tolerance"
  }
}
```

Run it over your whole backup folder once. **You will find at least one.** Almost everybody does.

---

## The rule, in one line

> **Never trust a date you typed into a filename. Only the filesystem knows when a file was written.**

*(And when you write the backup tool: make it tell the truth, or don't put the date in the name.)*

---

## Why this generalizes

The lying backup is one member of a family, and the family is the real lesson:

**A system that reports status without checking reality is worse than a system with no status at all** — because you stop looking. Every one of these is the same bug wearing different clothes:

- A process list that says *online* for a process whose every request has been returning **401** for four days.
- A JSON parser that says *valid* because the brackets balance, while the loader rejects the contents.
- A state file that *loads* fine and silently matches nothing, forever.
- A backup whose name describes an intention rather than a fact.

**In each case the machine answered a question you didn't ask, and you accepted it because the answer was formatted well.**

The countermeasure is always the same, and it's dull: **ask the question that can only be answered by the truth.** Read the mtime. Grep the log for 401. Round-trip the state file and compare. Parse *and* validate. Actually run it on a clean machine.

**Dull checks catch expensive bugs.** The exciting ones make better stories after the fact.

---

*Free to copy, quote, and repost. No attribution needed — just fix your backups.*
