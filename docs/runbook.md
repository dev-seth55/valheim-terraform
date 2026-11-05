# Valheim Dedicated Server — Terraform on AWS

Steam-only, 10-player-capable server on a `t3a.medium` (2 vCPU / 4GB RAM) in
`us-east-1` (N. Virginia). Persists across reboots via systemd; the address never
changes thanks to the attached Elastic IP.

## Cost (24/7, on-demand, us-east-1)

| Item                                  | Approx. monthly |
|---------------------------------------|-----------------|
| t3a.medium (~$0.0376/hr)              | ~$27            |
| 40 GB gp3 root volume                 | ~$3             |
| Public IPv4 address (billed since 2024, attached or not) | ~$4 |
| **Total**                             | **~$34**        |

With Discord start/stop and idle auto-stop (below), compute only bills while
someone is actually playing. A stopped server costs about **$7/month** (EBS + the
public IP). Twenty hours of play a week adds roughly $3.30 of compute on top.

CPU credit mode is set to **Unlimited**, so a long play session can burst past the
t3a.medium's baseline (20%/vCPU) without getting throttled mid-game. This only adds
cost if your *24-hour average* usage exceeds baseline, which won't happen with evening
sessions and idle time overnight — but if you ever see a "CPU Credit surplus" line
item, that's why, and it means the workload has outgrown this instance size (check
the CloudWatch `CPUCreditBalance` metric).

## Regions

Everything currently lives in `us-east-1`: the state bucket (`bootstrap/`,
referenced by the `backend "s3"` block in `main.tf`) and the server (`aws_region`
in `terraform.tfvars`). They don't have to match — Terraform reads the backend
region and the provider region separately — but the backend block must say
where the state bucket actually is.

## Order of operations

Nothing on your machine is a default AWS identity — that's deliberate. It means
even the very first command needs to be told who it's running as, so the
credential tooling comes before anything that talks to AWS:

0. **aws-vault + your admin key** (below) — installs the tool and stores the one
   credential that can create everything else.
1. **`bootstrap/`** — creates the S3 state bucket, run as `aws-vault exec admin`.
2. **`docs/iam-setup.md`** — creates the MFA-gated `terraform-deployer` role and the
   narrow caller user. Needs the bucket name from step 1.
3. **Build the PyNaCl layer** — `bash discord/layer/build-layer.sh` produces
   `discord/layer/pynacl-layer.zip`, which Terraform needs before the first plan.
   The zip is a third-party binary, so it's built locally rather than committed.
4. **This directory** — the actual server, run as `aws-vault exec terraform-deployer`.
   After this, the admin key can come back out of the vault.

## Prerequisites

- Terraform >= 1.11 installed locally (needed for native S3 state locking)
- Python 3 with pip, plus `zip`, to build the PyNaCl Lambda layer (step 3 above)
- An SSH key pair on your machine. Check with `ls ~/.ssh/id_ed25519.pub`; if it's
  not there, `ssh-keygen -t ed25519`. (If you'd rather use an existing RSA key, set
  `ssh_public_key_path` in `terraform.tfvars`.)
- Windows note: the docs use `vi` and `curl`. In PowerShell, `curl` is an alias for
  `Invoke-WebRequest` — use `curl.exe` if you need the real thing. `vi` is whatever
  you have on PATH (Git for Windows ships one).

## 0. aws-vault and the admin credential (once)

aws-vault stores AWS keys in the OS keychain (Windows Credential Manager, macOS
Keychain) and injects them into a single command's environment — nothing is ever
written to `~/.aws/credentials` in plaintext, and nothing is ambient.

1. Install it. Easiest on Windows:
   ```
   winget install 99designs.aws-vault
   ```
   Or download from https://github.com/99designs/aws-vault/releases — the Windows
   assets are `aws-vault-windows-386.exe` (32-bit; runs fine on 64-bit Windows,
   use this one) and `aws-vault-windows-arm64.exe` (Arm laptops only). Rename to
   `aws-vault.exe` and put it on your PATH. Either way, open a new terminal and
   verify with `aws-vault --version`.
2. Store the access key of an admin-level IAM user (whatever you use to administer
   the account today; not the root user if you can avoid it):
   ```
   aws-vault add admin
   ```
3. Give that profile a region in `~/.aws/config` (create the file if needed):
   ```
   [profile admin]
   region = us-east-1
   ```
4. Confirm it works:
   ```
   aws-vault exec admin -- aws sts get-caller-identity
   ```
   This needs the AWS CLI installed. If you don't have it, skip the check — the
   bootstrap `plan` in the next step will fail loudly if the credentials are bad.

The `admin` profile is used for steps 1 and 2 only. Once the deployer role works
(the identity check in `docs/iam-setup.md` step 8 passes), remove it: `aws-vault remove admin`.

## 1. Bootstrap the remote state bucket (once)

Terraform state for this project lives in S3 so it isn't tied to one laptop. The
bucket has to exist before `terraform init` will work here, because `main.tf`
already points at it.

1. `cd bootstrap/`
2. `cp terraform.tfvars.example terraform.tfvars` and set `bucket_name` to something
   globally unique (S3 bucket names collide across *all* AWS accounts, not just yours).
3. Run it as the admin profile — `bootstrap/` has no backend and no profile of its
   own, so a bare `terraform plan` here fails with "No valid credential sources found":
   ```
   aws-vault exec admin -- terraform init
   aws-vault exec admin -- terraform plan
   aws-vault exec admin -- terraform apply
   ```
4. Note the `bucket_name` output. You'll paste it into two more files later —
   `iam/deployer-permissions-policy.json` in step 2 and `main.tf` in step 3 — each
   at the point it's first needed. Nothing else to do here.
5. Keep `bootstrap/terraform.tfstate` somewhere safe (it's gitignored). The bucket
   has `prevent_destroy` on it, so a stray `destroy` here won't delete your state.

## 2. IAM role and caller user

Follow `docs/iam-setup.md`, then come back here. Console steps in that doc are done
as your admin user; any CLI steps use `aws-vault exec admin`.

## 3. Setup

1. Point the backend at your state bucket. In `main.tf`, replace the `bucket` value
   in the `backend "s3" {}` block with the name from bootstrap. This has to be a
   literal — the backend is resolved before variables are loaded, so it can't read
   one:
   ```
   vi main.tf
   ```
   If the name is wrong, `init` in step 3 fails immediately with "bucket does not
   exist" or "access denied" — there's no silent failure mode here.

2. Copy the example vars file and edit it:
   ```
   cp terraform.tfvars.example terraform.tfvars
   vi terraform.tfvars
   ```
   Confirm the SSH public key path and pick a server name / world name / password.
   Terraform validates the password up front: 5+ characters, must not contain the
   server name, and no `"`, `\`, `$`, or `` ` `` (it's embedded in a shell script).

   **You do not need to enter your IP.** Your current public IP is looked up at plan
   time and written into the security group's SSH rule — see "Dynamic home IP" below.

3. Initialize the working directory (downloads providers, connects to the S3 backend):
   ```
   aws-vault exec terraform-deployer -- terraform init
   ```

4. Review the plan — this shows every resource before anything is created:
   ```
   aws-vault exec terraform-deployer -- terraform plan
   ```

5. Apply it:
   ```
   aws-vault exec terraform-deployer -- terraform apply
   ```
   Type `yes` to confirm. AWS provisions the instance in about a minute; the Valheim
   binary then takes another 3-5 minutes to download via SteamCMD on first boot.
   The first command in a while prompts for your MFA code; aws-vault caches the
   session until it expires, so back-to-back commands won't re-prompt.

6. Grab the connection info:
   ```
   aws-vault exec terraform-deployer -- terraform output
   ```
   (This still needs credentials — it reads the state file back from S3.)

## Dynamic home IP

Port 22 is only open to one `/32`. Since a home connection's IP rotates, `main.tf`
fetches your current public IP from `checkip.amazonaws.com` every time you run
`plan` or `apply`, and the security group rule follows it.

- **If SSH suddenly times out**, your IP has probably changed. Re-run
  `aws-vault exec terraform-deployer -- terraform apply`. The plan will show one
  in-place update to `aws_security_group.valheim` and nothing else; nothing is
  replaced and the game isn't interrupted.
- `terraform output ssh_allowed_from` shows the CIDR currently allowed.
- To pin a fixed address instead (VPN exit, office IP), set `ssh_cidr_override` in
  `terraform.tfvars`.
- The game ports (2456-2457/udp) are open to everyone by necessity; only SSH is
  IP-restricted.

## Using a specific seed (or an existing world)

The dedicated server has no `-seed` argument; the seed is fixed inside the world
metadata when the world is first generated. To play a chosen seed, create the world
on your PC and upload it:

1. In the Valheim client: Worlds > New, enter the name (must equal `world_name` in
   `terraform.tfvars`) and the seed. Load in, wait a minute, exit to menu so a save
   completes. If the world is a Steam Cloud save, use the world manager's
   **Move to local** first.
2. Find the folder on Windows at
   `%USERPROFILE%\AppData\LocalLow\IronGate\Valheim\worlds_local\<world_name>\`
   and confirm it contains an `_main.N.ok` file.
3. Copy it up (PowerShell shown; adjust `<world_name>`):
   ```
   scp -i ~/.ssh/id_ed25519 -r "$env:USERPROFILE\AppData\LocalLow\IronGate\Valheim\worlds_local\<world_name>" ubuntu@<server_public_ip>:~/
   ```
4. On the server, stop the game, replace whatever it generated, fix ownership, start:
   ```
   sudo systemctl stop valheim
   sudo rm -rf /home/valheim/.config/unity3d/IronGate/Valheim/worlds_local/<world_name>
   sudo mv ~/<world_name> /home/valheim/.config/unity3d/IronGate/Valheim/worlds_local/
   sudo chown -R valheim:valheim /home/valheim/.config/unity3d/IronGate/Valheim/worlds_local/<world_name>
   sudo ls -la /home/valheim/.config/unity3d/IronGate/Valheim/worlds_local/<world_name>
   sudo systemctl start valheim
   ```
   No wildcards in the `rm` path: the shell expands globs as `ubuntu` *before*
   `sudo` runs, and `ubuntu` can't read inside `/home/valheim`, so a glob there
   silently matches nothing. The `ls` should show your `_main.N.*` files with
   their original timestamps before you start the server.
   Confirm with `sudo journalctl -u valheim -f`: `ZNet.LoadWorld: <world_name>
   (<world_name>), save number N` where N matches your `_main.N` files, and no
   "Generating locations" phase.

## Verifying it came up

SSH in with the private key that matches the public key you configured (the
`ssh_command` output has the full command) and check the service:
```
ssh -i ~/.ssh/id_ed25519 ubuntu@<server_public_ip>
sudo systemctl status valheim
sudo journalctl -u valheim -f
```
You're looking for a `Game server connected` line in the logs — that means it's
registered with Steam and ready for joins. Also confirm the name and world are
yours: `ZNet.LoadWorld: <your world_name>`. If you instead see `Dedicated`,
`"My server"`, or anything mentioning `PlayFab` / a join code, the server is
running Iron Gate's stock `start_server.sh` rather than ours — that means the
start script got written inside the SteamCMD install dir, where `validate`
overwrites it. Ours lives at `/home/valheim/start_valheim.sh` for that reason.

## Connecting

In Steam: **Valheim > Join Game > Join IP** > `<server_public_ip>:2456`, then enter
the password when prompted.

The server is listed in the Steam server browser (`server_public = true`), shown
with a lock because it's password-protected; friends still join by IP. It has to be
listed: Valheim only answers Steam A2S queries on port 2457 when it is, and both
`/valheim status` (player count) and the idle auto-stop depend on those queries.
With `-public 0` the game holds the port but never reads it. The idle check
treats "no answer" as unknown and never stops on it, so an unlisted server simply
never auto-stops.

**Steam only.** The server runs without `-crossplay`, so it uses the Steam backend:
join-by-IP works, and only Steam players can see or join it. Since 1.0 that also
means Xbox, PlayStation 5, and Nintendo Switch 2 players can't connect. Enabling
crossplay is a different setup (PlayFab backend, join codes instead of IP) and
isn't covered here.

## Day-to-day

- **World save location**: `/home/valheim/.config/unity3d/IronGate/Valheim/worlds_local/<world_name>/`
  Since Valheim 1.0 (Sept 2026) a world is a *directory* holding `_main.N.fwl2`,
  `_main.N.db2`, `_main.N.chunks`, `_main.N.ok`, and one `.chunk` file per terrain
  chunk. Always move the whole directory; a partial copy won't load and the server
  will generate a fresh world under that name instead. `_main.N.ok` present means
  the last save completed.
- **Restart the game process** (e.g. after manually editing config): `sudo systemctl restart valheim`
- **Start/stop the whole instance**: `/valheim start|stop|status` in Discord, or
  `aws-vault exec terraform-deployer -- aws ec2 start-instances --instance-ids <id>`
  (and `stop-instances`). The IP never changes; it's an Elastic IP.
- **Updating Valheim**: when Iron Gate ships a patch, Steam clients update
  automatically and can no longer join a server on the old version — so you'll be
  forced to update within a day or so of each patch. The instance does not update
  itself (deliberate: avoids surprise mid-session restarts). To update:
  ```
  ssh -i ~/.ssh/id_ed25519 ubuntu@<server_public_ip>
  sudo valheim-update
  ```
  That stops the service (Valheim saves on shutdown), snapshots `worlds_local/`
  to `/home/valheim/backups/` (last five kept), runs SteamCMD
  `+app_update 896660 validate`, and starts it again. Takes a minute or two;
  players get disconnected while it runs. SteamCMD only replaces game binaries —
  it never writes to `worlds_local/`, so the world is untouched. The snapshot
  exists because some patches migrate the save format one-way; if a patch is bad,
  you can roll the binaries back and restore the pre-patch tarball.
- **Changing the server name / world / password after the first boot**: the
  values in `terraform.tfvars` are only applied when the instance is first created
  (cloud-init runs the boot script once). To change them on a running server, edit
  the start script on the box and restart:
  ```
  sudo vi /home/valheim/start_valheim.sh
  sudo systemctl restart valheim
  ```
  Update `terraform.tfvars` to match so a future rebuild uses the same values.
  Terraform deliberately ignores `user_data` drift, so this won't show up in a plan.

## What's protected against

- The world save lives on the instance's root volume, so anything that *replaces*
  the instance destroys it. `main.tf` ignores changes to the AMI and subnet for
  exactly that reason: Canonical publishes new Ubuntu AMIs regularly, and without
  that guard the next `apply` after a release would rebuild the box. **Always read
  the plan**: if it ever says `aws_instance.valheim must be replaced`, stop and pull
  a copy of `worlds_local/` first.
- The state bucket is versioned, encrypted, and can't be destroyed by Terraform.
- `terraform.tfvars` (password, key path) and all state files are gitignored.

## Backups

Every hour, and after every graceful stop (patch, reboot, EC2 stop, `/valheim
stop`), the instance tars `worlds_local/` and uploads it to the S3 bucket in
`terraform output backup_bucket` under `<hostname>/worlds_local-<timestamp>.tar.gz`.
Hourly runs skip the upload when nothing has changed. Snapshots expire after
`backup_retention_days` (default 30). The bucket is versioned and encrypted; the
instance role can write to it and nothing else.

On the box: `/usr/local/bin/valheim-backup` (add `--force` to upload even if
unchanged), log at `/home/valheim/backups/backup.log`, config in
`/etc/valheim/backup.env`. The last five tarballs are also kept locally.

**Adding backups to an instance created before this existed:** `terraform apply`
attaches the instance role in place (no rebuild). Then install the on-box side
by hand — it's the same script `user_data` runs on new instances:
```
scp -i ~/.ssh/id_ed25519 scripts/install-backup.sh ubuntu@<server_public_ip>:~/
ssh -i ~/.ssh/id_ed25519 ubuntu@<server_public_ip>
sudo bash ~/install-backup.sh <backup_bucket>
sudo -u valheim /usr/local/bin/valheim-backup --force
```
The last command is the test: it should print an "uploaded" line, and
`aws s3 ls s3://<backup_bucket>/ --recursive` from your machine (via aws-vault
as `admin`, since the deployer role can't read object listings there) shows it.

**Restoring:**
```
sudo systemctl stop valheim
aws s3 cp s3://<backup_bucket>/<hostname>/worlds_local-<timestamp>.tar.gz /tmp/
sudo rm -rf /home/valheim/.config/unity3d/IronGate/Valheim/worlds_local
sudo tar -xzf /tmp/worlds_local-<timestamp>.tar.gz -C /home/valheim/.config/unity3d/IronGate/Valheim/
sudo chown -R valheim:valheim /home/valheim/.config/unity3d/IronGate/Valheim/worlds_local
sudo systemctl start valheim
```
(The instance role can `GetObject`, so this works from the box without extra
credentials. On a *new* instance after a `destroy`, the tarballs are still in the
bucket — `terraform destroy` doesn't remove it; delete it by hand if you want it
gone.)

## Discord control and idle auto-stop

Friends start and stop the server from Discord with `/valheim start`,
`/valheim stop`, and `/valheim status` (which shows the player count). A
scheduled check also stops the instance after `idle_minutes` (default 30) with
nobody online, so a forgotten server costs half an hour, not a weekend. Both run
in one small Lambda (`discord/lambda/handler.py`); it can start, stop, and tag
exactly one instance and nothing else.

`/valheim status` on an empty server also shows how long it has been empty and
roughly when the auto-stop will fire. `/valheim stop` refuses if players are
online unless you add `force:True`.
EC2 stop is a clean shutdown: systemd stops Valheim, the world saves, the
backup uploads, then the box powers off. Start takes about two minutes.

Making the function URL public takes three things, all in `discord.tf`:
`authorization_type = "NONE"`, plus a resource policy granting **both**
`lambda:InvokeFunctionUrl` and `lambda:InvokeFunction` to `*` (the console's
Function URL page says exactly this in a banner when either is missing). Missing
any of them gives a 403 from the URL before the handler ever runs. If all three
are present and it's still 403, look for a **Block public access** panel under
Configuration > Permissions in the Lambda console and uncheck it.

**What "public" means here.** Anyone who knows the URL can send it requests, and
anyone with AWS credentials who knows the function ARN can invoke it directly.
Neither gets them anything: Discord requests are Ed25519-verified before the
handler touches AWS, so unsigned requests get a 401; a direct invocation can
only reach the idle-check path, which at most stops a server that has already
been empty for `idle_minutes`. The Lambda's IAM role can start, stop, tag, and
describe exactly one instance — no access to the world, backups, state, IAM, or
the game password. Junk traffic costs are bounded by the account's Lambda
concurrency limit (10 for new accounts; Lambda won't let a single function
reserve less than that, which is why there's no `reserved_concurrent_executions`).
Quick check that all three are in place:
```
Set-Content -Path ping.json -Value '{"type":1}' -NoNewline
curl.exe -s -g -H "Content-Type: application/json" -d "@ping.json" <discord_interactions_url>
```
Healthy: `{"error": "invalid request signature"}` — the handler answering and
rejecting an unsigned request. `{"Message":"Forbidden..."}` means one of the
three is missing.

### One-time Discord setup

1. **Create the app.** https://discord.com/developers/applications > New
   Application. Note the **Application ID** and **Public Key** on General
   Information. Under Bot, click **Reset Token** and save the token somewhere
   safe (a password manager); it's only used for step 5.
2. **Get your server ID.** In Discord: User Settings > Advanced > Developer Mode
   on, then right-click your server > Copy Server ID.
3. **Tell Terraform.** In `terraform.tfvars`:
   ```
   discord_public_key = "<Public Key>"
   discord_guild_id   = "<Server ID>"
   ```
   then `aws-vault exec terraform-deployer -- terraform apply`. Note the
   `discord_interactions_url` output.
4. **Point Discord at the Lambda.** Back in the app's General Information page,
   paste that URL into **Interactions Endpoint URL** and save. Discord sends a
   signed test request; if the public key in tfvars is right it saves cleanly,
   otherwise it refuses with a validation error.
5. **Invite the app** to your server: OAuth2 > URL Generator > scope
   `applications.commands` (no bot permissions needed) > open the generated
   URL > pick your server > Authorize. This must come before registering the
   command; otherwise Discord answers `50001 Missing Access`. While you're in
   the portal, Bot > **Public Bot** off.
6. **Register the command** (once, and again only if `discord/commands.json`
   changes). From PowerShell in the project root:
   ```
   $env:DISCORD_APP_ID    = "<Application ID>"
   $env:DISCORD_GUILD_ID  = "<Server ID>"
   $env:DISCORD_BOT_TOKEN = "<Bot token>"
   powershell -ExecutionPolicy Bypass -File discord/register-commands.ps1
   ```
   Guild commands appear instantly. Type `/valheim status` in any channel.

Anyone in the server can use the commands. If you want to restrict it further
(a role, specific people), Discord's own **Integrations > valheim > Command
Permissions** settings do that without touching the code.

### How idle detection works

Every 5 minutes the Lambda sends a Steam A2S query to `<server_ip>:2457` (the
same query the Steam server browser uses) and reads the player count. Zero
players sets a `ValheimIdleSince` tag on the instance; players online clears it;
zero for `idle_minutes` stops the instance. The first `idle_minutes` after a boot
are a grace period. **No answer from the query port never causes a stop** — the
check only acts on a positively observed zero, so a booting or misconfigured
server is left alone rather than stopped under someone's feet. Quick check that
queries work, from the box:
```
printf '\xff\xff\xff\xffTSource Engine Query\x00' | nc -u -w 2 127.0.0.1 2457 | xxd | head -1
```
A reply starting `ffff ffff 49` (or `41`) means the responder is up. Logs are in CloudWatch under `/aws/lambda/valheim-control`
(14-day retention).

## Tearing down

```
aws-vault exec terraform-deployer -- terraform destroy
```
This deletes the instance, security group, key pair, EIP, Lambda, and IAM roles.
The backup bucket is **not** emptied or deleted (Terraform refuses to destroy a
non-empty bucket), so your snapshots survive a destroy; remove the bucket by hand
if you're done for good. **The world on the instance goes with it**, so either
trust the last S3 snapshot or pull a copy off first. On the server, stage a copy the
`ubuntu` user can read, then pull it down:
```
sudo systemctl stop valheim
sudo cp -r /home/valheim/.config/unity3d/IronGate/Valheim/worlds_local ~/worlds_local
sudo chown -R ubuntu:ubuntu ~/worlds_local
```
```
scp -i ~/.ssh/id_ed25519 -r ubuntu@<server_public_ip>:~/worlds_local ./worlds_local-backup
```

## Not built yet, worth adding later

- **SSM Session Manager**: the instance role now exists, so attaching
  `AmazonSSMManagedInstanceCore` to it unlocks `aws ssm start-session`, at which
  point port 22 can be closed entirely and the dynamic-IP lookup goes away.
- **Separate EBS volume for the world save**: decouples the data from the instance
  lifecycle, so you can swap instance types or rebuild without touching the save.

## Editor

`.vscode/` recommends the Terraform, Vim, and AWS Toolkit extensions and formats
`.tf` files on save. A fresh integrated terminal has no AWS identity — you invoke
`aws-vault exec terraform-deployer -- ...` explicitly whenever you need it.
