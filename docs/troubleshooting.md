# Troubleshooting and Lessons Learned

Every failure below actually happened while building and running this project.
Each entry gives the symptom, the root cause, and the fix that is now in the code
or the runbook. Grouped by layer.

---

## Setup ordering (credentials and IAM)

### `No valid credential sources found` when running `bootstrap/`
- **Cause:** The project deliberately has no default AWS identity, but the
  bootstrap step was originally documented as "run with your existing admin
  credentials". There weren't any on the machine.
- **Fix:** Step 0 of the runbook installs aws-vault and stores an `admin` profile
  *before* bootstrap; bootstrap commands run as `aws-vault exec admin -- ...`.
- **Lesson:** Review setup docs by executing them on a clean machine, not by
  reading them. Ask "what is the first command that can't run?"

### `Invalid principal in policy` when creating the deployer role
- **Cause:** The role's trust policy names `user/terraform-caller` as principal.
  IAM validates trust-policy principals at creation time, so the user must exist
  first. (Identity policies do *not* validate `Resource` ARNs, so the reverse
  order is fine.)
- **Fix:** IAM setup creates the caller user (step 2) before the role (step 3).

### `MultiFactorAuthentication failed, unable to validate MFA code`
- **Cause:** `mfa_serial` in `~/.aws/config` was guessed as
  `mfa/terraform-caller`. The real ARN ends in whatever device name was typed
  when the MFA was assigned.
- **Fix:** Copy the exact **Identifier** from IAM > Users > terraform-caller >
  Security credentials. The reference config uses `REPLACE_ME_MFA_DEVICE_ARN`.

### `sts.user-east-1.amazonaws.com: no such host`
- **Cause:** Typo `user-east-1` for `us-east-1` in `~/.aws/config`.
- **Fix:** Correct the region line. If the error persists, check
  `$env:AWS_REGION` / `$env:AWS_DEFAULT_REGION`, which override the file.

### aws-vault: "This app can't run on your PC"
- **Cause:** Downloaded the `windows-arm64` build on an x64 PC. The release has
  no `windows-amd64` asset.
- **Fix:** `winget install 99designs.aws-vault`, or use the `windows-386` build
  (32-bit runs fine on 64-bit Windows).

---

## Terraform

### `file()` can't find `~/.ssh/...pub`
- **Cause:** `file()` doesn't expand `~`.
- **Fix:** `file(pathexpand(var.ssh_public_key_path))`.

### Instance would be replaced (and world destroyed) on routine applies
- **Cause:** `most_recent = true` AMI lookup, unordered subnet list, and
  `user_data` edits all force or trigger instance changes. The world lives on the
  root volume.
- **Fix:** `lifecycle { ignore_changes = [ami, subnet_id, user_data,
  tags["ValheimIdleSince"]] }`. Always read the plan; "must be replaced" on
  `aws_instance.valheim` means stop and back up first.

### Every apply strips a tag from the instance
- **Cause:** The control Lambda sets `ValheimIdleSince` on the instance; Terraform
  saw it as drift and removed it, silently restarting the idle timer.
- **Fix:** Added that tag key to `ignore_changes`.

### `Backend configuration changed` after editing the backend block
- **Fix:** If no state exists in the old backend yet, use
  `terraform init -reconfigure`. Use `-migrate-state` only when there is state to
  copy (it will fail if the old bucket is gone).

### `AuthorizationHeaderMalformed ... expecting 'us-east-2'` in bootstrap
- **Cause:** A bucket name, once created, is pinned to its region until S3 releases
  it, even after deletion. Bootstrap ran in a different region than the bucket.
- **Fix:** Use a new bucket name when changing the state bucket's region. The
  backend block's `region` must be where the bucket actually lives; it is
  independent of the server region.

### `templatefile` error: `Invalid expression` in `user_data.sh.tpl`
- **Cause:** A comment in the template contained a literal `${...}`;
  `templatefile()` tries to interpolate comments too.
- **Fix:** Never write `${` in the template except for the intended variables.

### `-replace=aws_instance.valheim` rejected in PowerShell
- **Cause:** PowerShell split the argument at the dot.
- **Fix:** Quote it: `terraform apply "-replace=aws_instance.valheim"`.

### `Error: No configuration files`
- **Cause:** Running Terraform one directory too high (zip extracted into a
  folder of the same name).
- **Fix:** `cd` into the folder that contains `main.tf`.

---

## Instance boot and game server

### Server came up as "My server", world "Dedicated", crossplay on
- **Cause:** The custom `start_server.sh` was written into the SteamCMD install
  directory *before* `app_update ... validate`, which overwrote it with Iron
  Gate's stock script.
- **Fix:** The start script lives at `/home/valheim/start_valheim.sh`, outside
  anything SteamCMD manages.

### `cloud-init status: error`, `Failed to install app '896660' (Missing configuration)`
- **Cause:** Known SteamCMD flake on the first `app_update` right after it
  self-updates.
- **Fix:** `valheim-update` retries `app_update` up to three times. On an
  instance that already failed: `sudo valheim-update`. Note that cloud-init
  records the first-boot result permanently, so `status: error` stays on that
  instance even after recovery.

### `E: Package 'awscli' has no installation candidate`
- **Cause:** Ubuntu 24.04 dropped the `awscli` apt package (snap only).
- **Fix:** `install-backup.sh` installs AWS CLI v2 from AWS's official zip.

### World path is wrong / `mv: No such file or directory`
- **Cause:** Unity saves under the *user's home*, not the working directory. The
  real path is `/home/valheim/.config/unity3d/IronGate/Valheim/worlds_local/`,
  not under `valheim-server/`.

### `rm -rf .../<WorldName>*` silently does nothing; next `mv` fails
- **Cause:** The glob is expanded by the calling shell (as `ubuntu`) before
  `sudo` runs, and `ubuntu` can't read inside `/home/valheim`. The literal `*`
  matches nothing and `rm -f` stays quiet.
- **Fix:** No globs under `sudo` for that tree; use exact paths, or
  `sudo sh -c '...'` when a glob is needed.

### Uploaded world not loaded; server generated a new one
- **Cause:** Valheim 1.0 (Sept 2026) changed worlds from a `.fwl`/`.db` pair to a
  folder of `_main.N.fwl2`, `_main.N.db2`, `_main.N.chunks`, `_main.N.ok`, and
  `.chunk` files. Also: `-world <name>` creates a new world if no folder of that
  name exists, so a misplaced upload fails silently.
- **Fix:** Upload the whole folder; verify with the log line
  `ZNet.LoadWorld: <name> (<name>), save number N` matching the uploaded `N`,
  and no `Loading: Generating locations` line.

### Local world folder has only `cacheMinimap*` files
- **Cause:** The world is a Steam Cloud save.
- **Fix:** Use "Move to local" in the client's world manager, or turn off Steam
  Cloud when creating the world.

### Server older than clients (e.g. server 1.0.12, client 1.0.15)
- **Cause:** Steam auto-updates clients; the server only updates when told.
  Clients can still join if the *network version* matches, which hides the gap.
- **Fix:** `sudo valheim-update`, then confirm
  `journalctl -u valheim | grep "Valheim version"`.
- **Related:** A patch of missing vegetation in already-explored zones appeared
  while versions were mismatched. Valheim never regenerates a zone once
  generated, so the world was recreated from the same seed with server and
  client on the same build. Whether the gap was the cause is not yet confirmed.

### Shader / `AsyncResourceUpload failed` / `referenced script is missing` log lines
- Harmless. The dedicated server runs Unity with a null graphics device and logs
  every effect it can't initialize.

---

## Discord control and the Lambda

### `/valheim status` says "not answering"; idle check never stops the server
- **Cause:** With `-public 0`, Valheim holds UDP 2457 but never answers Steam A2S
  queries (`ss -ulnp` showed a growing Recv-Q). Player count is unknowable.
- **Fix:** `server_public = true` (listed, password-protected). The idle check now
  refuses to act on an unknown count, so it fails safe instead of stopping a
  server people may be on.
- **Check from the box:**
  `printf '\xff\xff\xff\xffTSource Engine Query\x00' | nc -u -w 2 127.0.0.1 2457 | xxd | head -1`
  should start `ffff ffff 49` or `41`.

### Discord: "interactions endpoint url could not be verified"; URL returns 403 `Forbidden`
- **Cause:** A function URL with `authorization_type = "NONE"` also needs a
  resource policy granting **both** `lambda:InvokeFunctionUrl` *and*
  `lambda:InvokeFunction` to `*`. The console's Function URL page shows a banner
  saying exactly this.
- **Fix:** `aws_lambda_permission.public_url` and `.public_invoke` in
  `discord.tf`. Healthy URL check: an unsigned POST returns
  `{"error": "invalid request signature"}` (401).

### `FunctionUrlAuthType is only supported for lambda:InvokeFunctionUrl action`
- **Cause:** The `function_url_auth_type` condition was also put on the
  `InvokeFunction` permission.
- **Fix:** That grant is unconditional.

### `ReservedConcurrentExecutions ... below its minimum value of [10]`
- **Cause:** New accounts have a total Lambda concurrency of 10, and at least 10
  must stay unreserved, so no function can reserve any.
- **Fix:** Removed `reserved_concurrent_executions`; the account limit already
  caps runaway cost.

### `aws lambda put-public-access-block-config`: invalid choice
- The AWS CLI build in use (2.36.x on Windows) doesn't expose that subcommand,
  even though the API is documented. It turned out not to be needed; the missing
  `InvokeFunction` permission was the real cause of the 403.

### Registering the slash command: `{"code": 40333, "message": "internal network error"}`
- **Cause:** Discord's edge rejects Windows PowerShell's default User-Agent.
- **Fix:** `register-commands.ps1` sends a `DiscordBot (url, version)`
  User-Agent and forces TLS 1.2.

### Registering the slash command: `50001 Missing Access`
- **Cause:** The app hadn't been added to the server yet.
- **Fix:** Invite the app (OAuth2 URL with the `applications.commands` scope)
  *before* registering.

### `.ps1 cannot be loaded because running scripts is disabled`
- **Fix:** `powershell -ExecutionPolicy Bypass -File discord/register-commands.ps1`
  (one run only; doesn't change system policy).

---

## Windows / PowerShell quirks

- **Native commands lose inner quotes** in Windows PowerShell 5.1: pass JSON to
  the AWS CLI via `file://payload.json` rather than inline.
- **`curl` is an alias** for `Invoke-WebRequest`; use `curl.exe`. Add `-g` when
  the body or URL contains `{}`, or curl treats them as URL globs.
- **`Invoke-WebRequest -SkipHttpErrorCheck`** doesn't exist in 5.1.
- **.NET file APIs ignore PowerShell's current directory**; pass full paths to
  `[System.IO.File]::ReadAllBytes`.
- **`sudo` in PowerShell** is the Windows sudo feature, not the server's. Server
  commands go in the SSH session.

## SSH

- **"Incorrect passphrase" on a key restored from a password manager:** the
  `.pub` half can be intact while the encrypted body is unusable (or the stored
  passphrase belongs to a different copy). `ssh-keygen -y -f <key>` tests the
  passphrase in isolation. The resolution was to generate a new key and replace
  the instance with `-replace`.
- **`REMOTE HOST IDENTIFICATION HAS CHANGED`** after any instance replacement:
  expected, because the Elastic IP is reused by a new host.
  `ssh-keygen -R <ip>` clears the old entry.
- **SSH times out after the home IP changes:** re-run `terraform apply`; the
  security group follows the auto-detected IP in place.
