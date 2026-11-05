# Registers the /valheim slash command with Discord for one guild (server).
# Guild-scoped commands appear instantly; global ones can take up to an hour.
# Run once after `terraform apply`, and again only if commands.json changes.
#
# Needs three values from the Discord Developer Portal / your Discord client:
#   $env:DISCORD_APP_ID    - General Information > Application ID
#   $env:DISCORD_BOT_TOKEN - Bot > Token (Reset Token if you never copied it)
#   $env:DISCORD_GUILD_ID  - right-click your server > Copy Server ID
#                            (needs Developer Mode on in Discord settings)
#
# The bot token is only used here, from your shell. Terraform never sees it.
$ErrorActionPreference = "Stop"
foreach ($v in "DISCORD_APP_ID", "DISCORD_BOT_TOKEN", "DISCORD_GUILD_ID") {
  if (-not (Get-Item "Env:$v" -ErrorAction SilentlyContinue)) { throw "Set `$env:$v first." }
}
$uri  = "https://discord.com/api/v10/applications/$env:DISCORD_APP_ID/guilds/$env:DISCORD_GUILD_ID/commands"
$body = Get-Content (Join-Path $PSScriptRoot "commands.json") -Raw
# Discord's edge returns {"code":40333,"message":"internal network error"} to
# Windows PowerShell's default User-Agent; identify as a bot per their docs.
$ua = "DiscordBot (https://github.com/dev-seth55/valheim-terraform, 1.0)"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$resp = Invoke-RestMethod -Method Put -Uri $uri -ContentType "application/json" -UserAgent $ua `
  -Headers @{ Authorization = "Bot $env:DISCORD_BOT_TOKEN" } -Body $body
$resp | ForEach-Object { "Registered /$($_.name) (id $($_.id))" }
