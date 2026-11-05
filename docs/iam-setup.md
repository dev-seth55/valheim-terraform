# IAM Role Setup (one-time, manual)

## Why this is manual, once

Terraform can't create the identity it will later use to authenticate —
something with real permissions has to exist first. So this is done by hand,
one time, using whatever admin/root credentials you already used for
`bootstrap/`. After this, you never touch a long-lived access key again for
day-to-day work.

**Order matters**: by now you should have aws-vault installed with an `admin`
profile (runbook, step 0) and the state bucket created by `bootstrap/`
(step 1) — the deployer policy below references that bucket by name, so it
needs to already exist. Console steps here are done as the same admin user.

## 1. Find your account ID

```
aws sts get-caller-identity
```
Note the `Account` value. You'll replace two placeholders in the files here:

| Placeholder   | Replace with                                   | Appears in                                              |
|---------------|------------------------------------------------|---------------------------------------------------------|
| `REPLACE_ME_AWS_ACCOUNT_ID`     | the `Account` value above                        | `trust-policy.json`, `terraform-caller-user-policy.json`, `iam/deployer-permissions-policy.json`, `aws-config-reference.txt` |
| `REPLACE_ME_STATE_BUCKET`    | the `bucket_name` output from `bootstrap/`        | `iam/deployer-permissions-policy.json` (two occurrences)   |
| `REPLACE_ME_MFA_DEVICE_ARN` | the MFA device Identifier from step 4            | `aws-config-reference.txt`                             |

## 2. Create the narrow caller user

This comes *before* the role: the role's trust policy names this user as its
principal, and IAM validates trust-policy principals against identities that
already exist. Creating the role first fails with "Invalid principal in policy".

IAM > Users > Create user > name it `terraform-caller` > do NOT attach any
AWS-managed policies > after creation, add an inline policy using
`terraform-caller-user-policy.json` (with your account ID filled in) — this
user's only power is assuming the role in the next step, and only with valid
MFA. (It's fine that the role doesn't exist yet; IAM doesn't check `Resource`
ARNs in an identity policy.)

Then: that user > Security credentials > Create access key > choose
"Command Line Interface (CLI)" > save the Access Key ID and Secret Access Key
— this is the one and only long-lived credential in this whole setup.

## 3. Create the deployer role (console is easiest for a one-off)

IAM > Roles > Create role > "Custom trust policy" > paste in
`trust-policy.json` (with your account ID filled in) > Next > skip attaching
a managed policy for now > name it `terraform-deployer` > Create.

Then: open that role > Add permissions > Create inline policy > JSON tab >
paste in `iam/deployer-permissions-policy.json` > name it
`terraform-deployer-permissions` > Create. **Before pasting**, edit the file
and replace `REPLACE_ME_STATE_BUCKET` (both occurrences) with the `bucket_name` output
from `bootstrap/`, and every `REPLACE_ME_AWS_ACCOUNT_ID` with the value from
step 1 (the IAM, Lambda, and EventBridge statements are account-scoped). This is the
first of two places the bucket name is needed; the other is `main.tf` in the
runbook, step 3.

What this role can do: manage EC2 instances, security groups, key pairs, and
Elastic IPs (including the stop/start and attribute changes Terraform needs
for in-place updates); read/write the state bucket; and create the pieces
the backup and Discord features need — IAM roles and instance profiles named
`valheim-*`, Lambda functions and layers named `valheim-*`, EventBridge rules
named `valheim-*`, their log groups, and S3 buckets named `valheim-backups-*`.
Nothing outside those name patterns.

**When this file changes** (it did when backups and Discord control were
added), paste the new version over the existing inline policy: IAM > Roles >
terraform-deployer > Permissions > terraform-deployer-permissions > Edit >
JSON. Same placeholders as before.

## 4. Enable a virtual MFA device on terraform-caller

That user > Security credentials > Assign MFA device > Authenticator app >
scan the QR code with an authenticator app (Authy, Google Authenticator,
1Password, etc.) > enter two consecutive codes to confirm.

Then copy the device's ARN: back on the Security credentials tab, the MFA
table shows an **Identifier** column, e.g.
`arn:aws:iam::REPLACE_ME_AWS_ACCOUNT_ID:mfa/terraform-caller-phone`. The last segment is
the device name you chose, not the username — copy the whole string exactly.
You'll paste it as `mfa_serial` in step 7.

This is what makes the "session login" work: the trust policy on
`terraform-deployer` (see `trust-policy.json`) refuses to hand out the role
at all unless the request carries a valid MFA code less than an hour old.

## 5. aws-vault

Already installed in runbook step 0. If you skipped that, do it now:
`winget install 99designs.aws-vault` (or the `windows-386.exe` from
https://github.com/99designs/aws-vault/releases), then `aws-vault --version`.

## 6. Store the caller's credentials in aws-vault (not in a plaintext file)

```
aws-vault add terraform-caller
```
It'll prompt for the Access Key ID and Secret Access Key from step 2 —
these get encrypted into Windows Credential Manager (or macOS Keychain),
never written to `~/.aws/credentials` as plaintext.

## 7. Configure the two profiles

Add the `terraform-caller` and `terraform-deployer` blocks from
`aws-config-reference.txt` into `~/.aws/config` (the `admin` block is already
there from runbook step 0), with your real account ID in place of
`REPLACE_ME_AWS_ACCOUNT_ID` and the device Identifier from step 4 in place of
`REPLACE_ME_MFA_DEVICE_ARN`. This file holds configuration
only — no secrets — so it's fine for it to exist in plaintext.

## 8. Verify the MFA-gated session works

Note this runs as `terraform-deployer`, even though the only key you stored
is `terraform-caller`'s. That's the point: the deployer profile has no key of
its own — aws-vault follows its `source_profile` to the caller's stored key,
assumes the role with your MFA code, and hands the command short-lived role
credentials. This one check exercises the whole chain.

```
aws-vault exec terraform-deployer -- aws sts get-caller-identity
```
This prompts for your authenticator app's 6-digit code, then prints an
identity. The `Arn` should show `assumed-role/terraform-deployer/...` —
confirming the MFA-gated assumption succeeded.

## 9. Day-to-day usage

Every Terraform command gets wrapped:
```
aws-vault exec terraform-deployer -- terraform plan
aws-vault exec terraform-deployer -- terraform apply
```
The first call in a while prompts for MFA; aws-vault caches the resulting
session until it expires, so back-to-back commands within that window won't
re-prompt. A bare `terraform plan` with no wrapper has no credentials at all
— that's the "nothing is a default identity" property, enforced by the tool
rather than by a script we wrote ourselves.

If you'd rather not prefix every single command, `aws-vault exec
terraform-deployer -- pwsh` opens a sub-shell with the session's temporary
credentials exported for its lifetime — still session-scoped, still expires,
just fewer keystrokes per command.

## 10. Retire the admin key

The deployer role now covers everything the Valheim project needs, so the admin
credential has no ongoing job on this machine:
```
aws-vault remove admin
```
(Leave the `[profile admin]` block in `~/.aws/config` or delete it — it holds no
secret either way.)

Now go back to `docs/runbook.md` and continue from "3. Setup".
