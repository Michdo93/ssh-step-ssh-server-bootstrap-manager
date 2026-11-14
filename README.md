# SSH step SSH Server Bootstrap Manager

An interactive Bash utility that scans an IPv4 range for SSH services and runs
[step-ssh-server-bootstrap-kit](https://github.com/Michdo93/step-ssh-server-bootstrap-kit) on the
selected devices: every SSH server then accepts **SSH user certificates of your step-ca**
(`TrustedUserCAKeys`), optional **local accounts** and **principal mappings** are set up, and sshd is
restarted safely. Afterwards the tool can **test a certificate login** on every device.

It works like [ssh-step-cli-bootstrap-manager](https://github.com/Michdo93/ssh-step-cli-bootstrap-manager),
[ssh-dns-manager](https://github.com/Michdo93/ssh-dns-manager) and
[ssh-hostname-manager](https://github.com/Michdo93/ssh-hostname-manager): settings → range → scan →
confirm each device → user name → up to three login attempts → summary.

Part of the set
[step-ca-ssh-bootstrap-kit](https://github.com/Michdo93/step-ca-ssh-bootstrap-kit) (CA) ·
[step-ssh-server-bootstrap-kit](https://github.com/Michdo93/step-ssh-server-bootstrap-kit) (servers) ·
[step-ssh-client-bootstrap-kit](https://github.com/Michdo93/step-ssh-client-bootstrap-kit) (clients) ·
**ssh-step-ssh-server-bootstrap-manager** (servers over SSH).

## Requirements

- Bash 4 or newer, OpenSSH client (`ssh`), `timeout`, `xargs`, `base64` (Linux, WSL).
- Targets: Debian, Ubuntu, Raspberry Pi OS or DietPi with an SSH server and Internet access
  (the kit downloads the step CLI via [step-cli-bootstrap](https://github.com/Michdo93/step-cli-bootstrap)).
- A remote account that is root or may use `sudo`. The sudo password is typed into the remote prompt.
- SSH must be enabled on the CA (`step-ca-ssh.sh enable-ssh`).
- For the optional login test: a key with certificate on this machine, e.g. from
  [step-ssh-client-bootstrap-kit](https://github.com/Michdo93/step-ssh-client-bootstrap-kit)
  (`~/.ssh/step_sysadmin` + `~/.ssh/step_sysadmin-cert.pub`).

## Run

```bash
chmod +x deploy-step-ssh-server.sh
./deploy-step-ssh-server.sh
```

1. **Settings** (once for all devices):
   - step-ca URL, e.g. `https://192.168.0.150`
   - SHA-256 fingerprint of the root certificate (`step-ca-ssh.sh info` on the CA)
   - local accounts to create if missing, e.g. `ansible,sysadmin` – created with home and bash but
     **without a usable password** (certificate login only); optionally some of them in group `sudo`
   - principal mappings, e.g. `root=sysadmin` (a sysadmin certificate may also log in as root);
     several lines possible, Enter to finish
   - DietPi with Dropbear: replace Dropbear by OpenSSH automatically (Dropbear cannot use certificates)
2. **Login test** (optional): key file and the accounts to test, e.g. `sysadmin,root`.
3. **Range**: first and last IPv4 address, e.g. `192.168.0.1` – `192.168.0.254`.
4. **Scan**: 32 parallel probes, no ping needed, no host keys stored while scanning.
5. **Per device**: confirm, enter the SSH user name (the last one is offered as default), up to three
   login attempts. The kit runs with `sudo` (or directly as root), then the certificate login is tested.

## Example output

```text
Device: 192.168.0.5
Configure this SSH server for step-ca certificates? [Y/n] y
SSH username: helper
SSH login attempt 1 of 3 for 192.168.0.5.
[sudo] password for helper:
[INFO] Detected OS: Debian GNU/Linux 12 (bookworm) (x86_64)
==> Fetching the SSH user CA key from https://192.168.0.150
[INFO] Root certificate verified against the fingerprint (/etc/step-ssh-server/step/certs/root_ca.crt).
==> Local accounts
[INFO]   ansible created (no password - certificate login only)
[INFO]   sysadmin exists
==> Principal mappings
[INFO]   root <- sysadmin
==> Configuring sshd
[INFO] sshd -t: configuration OK.
[INFO] ssh.service restarted.
step-ssh-server-bootstrap-kit finished successfully on 192.168.0.5.
  certificate login sysadmin@192.168.0.5 -> OK (sysadmin)
  certificate login root@192.168.0.5     -> OK (root)

Finished. Configured: 3 (192.168.0.5 192.168.0.21 192.168.0.22), failed: 1 (192.168.0.23), certificate test failed: 0
```

Results per device: `SUCCESS`, `PRIVILEGE` (no root/sudo), `UNSUPPORTED` (not Debian-based / no bash),
`DOWNLOAD_FAILED`, `INSTALL_FAILED` (a rejected sshd configuration is rolled back by the kit), login failed
after three attempts, changed host key (verify, then `ssh-keygen -R <ip>`).

## Options (environment)

| Variable | Default | Meaning |
|---|---|---|
| `SSH_PORT` | `22` | SSH port for scan, login and test |
| `CONNECT_TIMEOUT` | `4` | seconds per connection attempt |
| `SCAN_PARALLEL` | `32` | parallel probes while scanning |
| `SSH_USER` | – | default SSH user name for the first device |
| `INSTALLER_URL` | `install.sh` of step-ssh-server-bootstrap-kit (`main`) | other installer, e.g. a fork |
| `INSTALLER_ENV` | – | `VAR=value` words for the kit, e.g. `"STEP_CLI_BOOTSTRAP_URL=http://mirror/install.sh"` |

## How it works

The remote part is a short POSIX-sh script sent base64-encoded **as the remote command** of `ssh -tt` –
not on stdin – so the remote terminal stays connected to your keyboard (sudo password) and the script
text is never echoed back. It checks for Linux/apt/bash and privileges, downloads the kit with `wget` or
`curl` (installs `wget` if neither exists) and runs it with `sudo bash`. A hidden result marker tells the
local side whether the kit succeeded. sshd is restarted by systemd, so the running session survives.

## Notes

- **DietPi + Dropbear:** after the switch to OpenSSH the device has a **new host key**. The login test
  then reports it; verify the device and run `ssh-keygen -R <ip>`.
- New accounts have no password (`*` in `/etc/shadow`, not locked): certificate login works, password
  login does not. For `sudo` with such an account set a password once (`sudo passwd sysadmin`) or add a
  sudoers rule.
- Mapping to `root` is powerful – only map certificates of administrators.

## License

MIT License. Feel free to use and modify.
