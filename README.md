# koha-sip-watchdog

A diagnostic and recovery script for Koha SIP2 server processes on multi-tenant Debian/Ubuntu installations managed by L2C2 Technologies.

---

## Background

Koha's SIP server is managed by the `daemon` utility, which forks a SIPServer master process that in turn pre-forks a pool of workers. Under certain failure conditions — most commonly a logrotate-induced pipe drain interruption — the SIPServer master dies but the `daemon` parent fails to reap it, leaving a zombie. The pre-forked workers become orphaned (reparented to PID 1) with no live pipe reader on their stdout. The 64KB kernel pipe buffer slowly fills with log output until every worker blocks in `pipe_w` — at which point SIP connections are accepted but permanently hang before sending the `login:` prompt.

This script detects and optionally repairs that condition across all SIP-enabled instances on the server.

---

## Requirements

- Must be run as `root` (or via `sudo`)
- `koha-list` must be available in `PATH`
- Tested on Koha 24.x, Debian 12 / Ubuntu 22.04+

---

## Installation

```bash
sudo cp koha-sip-watchdog.sh /usr/local/sbin/
sudo chmod 750 /usr/local/sbin/koha-sip-watchdog.sh
```

---

## Usage

```bash
# Report problems without making any changes (default)
sudo koha-sip-watchdog.sh --dry-run

# Detect and fix all issues
sudo koha-sip-watchdog.sh --fix

# Custom log file location
sudo koha-sip-watchdog.sh --fix --log /tmp/sip-fix.log
```

If no mode flag is supplied, `--dry-run` is assumed.

---

## What it checks

The script iterates over all instances returned by `koha-list` and skips any that do not have the file:

```
/var/lib/koha/<instance>/sip.enabled
```

For each SIP-enabled instance it checks:

| Check | Detail |
|-------|--------|
| Daemon present | `daemon --name=<instance>-koha-sip` process exists |
| Zombie master | Direct child of the daemon with stat `Z` |
| Orphaned workers | SIP worker processes with `ppid=1` |
| Pipe-blocked workers | SIP worker processes with `wchan=pipe_w` |

---

## What `--fix` does

1. Kills all orphaned and pipe-blocked worker PIDs (`kill -9`)
2. Kills the SIP daemon (`kill -9`) — this allows the kernel to reap the zombie master
3. Waits 2 seconds for reaping to complete
4. Runs a second sweep to kill any lingering processes
5. Calls `koha-sip --start <instance>` for a clean restart
6. Logs the outcome

---

## Log output

All output is written to both stdout and the log file (default `/var/log/koha/koha-sip-watchdog.log`).

Example output for a healthy instance:
```
[2026-03-26 10:00:01] [INFO] rksmvv: OK
[2026-03-26 10:00:01] [INFO] All SIP-enabled instances healthy
```

Example output when issues are found and fixed:
```
[2026-03-26 10:00:01] [WARN] rksmvv: 7 issue(s) — zombies=24584 orphans/blocked=25085 25092 25626 25632 26551 26560
[2026-03-26 10:00:03] [INFO] rksmvv: restarted OK
[2026-03-26 10:00:03] [WARN] Total issues: 7 — mode=fix
```

---

## Why this script was written

The specific failure sequence this script helped recover from:

```
logrotate runs at 00:00
  → rotates sip.log
  → daemon loses read end of pipe or stops draining
  → pipe buffer (64KB) fills slowly over hours
  → next worker write() blocks → pipe_w
  → all 6 workers eventually stuck in pipe_w
  → SIP connections accepted but no login: prompt never sent
  → ACS/RFID terminals time out silently
```

---

## Permanent fix

To prevent recurrence, add a SIP restart to the logrotate `postrotate` block in `/etc/logrotate.d/koha-common`:

```
postrotate
    /etc/init.d/apache2 reload > /dev/null
    for instance in $(koha-list); do
        [ -f "/var/lib/koha/${instance}/sip.enabled" ] && koha-sip --restart $instance > /dev/null 2>&1 || true
    done
endscript
```

---

## Author

Indranil Das Gupta
