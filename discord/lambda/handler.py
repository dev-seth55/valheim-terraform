"""
Valheim control Lambda.

Two entry points, one function:

1. Discord interactions (via the Lambda function URL). Discord POSTs every
   slash-command invocation here, signed with the app's Ed25519 key. We verify
   the signature, check the request came from our guild, and run
   /valheim start|stop|status against the EC2 instance.

2. Idle check (via an EventBridge schedule, every 5 minutes). Asks the game
   server for its player count over Steam's A2S query protocol. If the count
   has been zero for IDLE_MINUTES, stop the instance. The "idle since" marker
   is kept as a tag on the instance so this stays stateless.

Discord requires a reply within 3 seconds; every EC2 call here is fast and the
A2S query has a short timeout, so we answer synchronously.
"""

import json
import os
import socket
import struct
import time
from datetime import datetime, timezone

import boto3
from nacl.exceptions import BadSignatureError
from nacl.signing import VerifyKey

DISCORD_PUBLIC_KEY = os.environ.get("DISCORD_PUBLIC_KEY", "")
DISCORD_GUILD_ID = os.environ.get("DISCORD_GUILD_ID", "")
INSTANCE_ID = os.environ["INSTANCE_ID"]
SERVER_IP = os.environ["SERVER_IP"]
GAME_PORT = int(os.environ.get("GAME_PORT", "2456"))
QUERY_PORT = GAME_PORT + 1
IDLE_MINUTES = int(os.environ.get("IDLE_MINUTES", "30"))
IDLE_TAG = "ValheimIdleSince"

ec2 = boto3.client("ec2")


# --------------------------------------------------------------------------
# EC2 helpers
# --------------------------------------------------------------------------
def instance():
    r = ec2.describe_instances(InstanceIds=[INSTANCE_ID])
    return r["Reservations"][0]["Instances"][0]


def state_of(inst):
    return inst["State"]["Name"]


def tag_value(inst, key):
    for t in inst.get("Tags", []):
        if t["Key"] == key:
            return t["Value"]
    return None


# --------------------------------------------------------------------------
# Steam A2S_INFO query: returns (server_name, players, max_players) or None
# --------------------------------------------------------------------------
def a2s_info(timeout=1.5):
    req = b"\xff\xff\xff\xffTSource Engine Query\x00"
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(timeout)
            s.sendto(req, (SERVER_IP, QUERY_PORT))
            data, _ = s.recvfrom(4096)
            # Newer Steam servers answer with a challenge first; resend with it.
            if len(data) >= 9 and data[4:5] == b"A":
                s.sendto(req + data[5:9], (SERVER_IP, QUERY_PORT))
                data, _ = s.recvfrom(4096)
        if data[4:5] != b"I":
            return None
        pos = 6  # skip header (4) + 'I' (1) + protocol (1)

        def read_str():
            nonlocal pos
            end = data.index(b"\x00", pos)
            s_ = data[pos:end].decode("utf-8", "replace")
            pos = end + 1
            return s_

        name = read_str()
        read_str()  # map
        read_str()  # folder
        read_str()  # game
        pos += 2  # app id
        players, max_players = struct.unpack_from("BB", data, pos)
        return name, players, max_players
    except (socket.timeout, OSError, ValueError, struct.error):
        return None


# --------------------------------------------------------------------------
# Idle check (EventBridge)
# --------------------------------------------------------------------------
def idle_check():
    inst = instance()
    st = state_of(inst)
    if st != "running":
        return {"state": st, "action": "none"}

    # Grace period after boot: the game takes a couple of minutes to come up,
    # and a fresh start with nobody joined yet shouldn't be stopped instantly.
    launched = inst["LaunchTime"]
    uptime_min = (datetime.now(timezone.utc) - launched).total_seconds() / 60
    if uptime_min < IDLE_MINUTES:
        return {"state": st, "action": "grace", "uptime_min": round(uptime_min)}

    info = a2s_info()
    if info is None:
        # No answer on the query port. Either still booting, or the server is
        # running with -public 0 (Valheim only services A2S when listed).
        # Never stop on "unknown": leave the idle marker alone and try again
        # in five minutes.
        return {"state": st, "players": None, "action": "unreachable"}
    players = info[1]
    now = int(time.time())

    if players > 0:
        if tag_value(inst, IDLE_TAG):
            ec2.delete_tags(Resources=[INSTANCE_ID], Tags=[{"Key": IDLE_TAG}])
        return {"state": st, "players": players, "action": "active"}

    since = tag_value(inst, IDLE_TAG)
    if since is None:
        ec2.create_tags(Resources=[INSTANCE_ID], Tags=[{"Key": IDLE_TAG, "Value": str(now)}])
        return {"state": st, "players": 0, "action": "idle-start"}

    idle_min = (now - int(since)) / 60
    if idle_min >= IDLE_MINUTES:
        ec2.stop_instances(InstanceIds=[INSTANCE_ID])
        ec2.delete_tags(Resources=[INSTANCE_ID], Tags=[{"Key": IDLE_TAG}])
        return {"state": st, "players": 0, "action": "stopped", "idle_min": round(idle_min)}
    return {"state": st, "players": 0, "action": "idle", "idle_min": round(idle_min)}


# --------------------------------------------------------------------------
# Discord
# --------------------------------------------------------------------------
def verify(event, body):
    if not DISCORD_PUBLIC_KEY:
        return False
    h = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    sig = h.get("x-signature-ed25519")
    ts = h.get("x-signature-timestamp")
    if not sig or not ts:
        return False
    try:
        VerifyKey(bytes.fromhex(DISCORD_PUBLIC_KEY)).verify(
            (ts + body).encode(), bytes.fromhex(sig)
        )
        return True
    except (BadSignatureError, ValueError):
        return False


def respond(status, obj):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(obj),
    }


def message(text):
    return respond(200, {"type": 4, "data": {"content": text}})


def cmd_status():
    inst = instance()
    st = state_of(inst)
    if st != "running":
        return f"Server is **{st}**. Use `/valheim start` to bring it up."
    info = a2s_info()
    if info is None:
        return (
            f"Instance is running but the game isn't answering yet "
            f"(booting, or Steam registration in progress). Join at `{SERVER_IP}:{GAME_PORT}` in a minute."
        )
    name, players, maxp = info
    line = f"**{name}** is up at `{SERVER_IP}:{GAME_PORT}` — {players}/{maxp} players online."
    if players == 0:
        since = tag_value(inst, IDLE_TAG)
        if since:
            idle_min = int((time.time() - int(since)) / 60)
            left = max(IDLE_MINUTES - idle_min, 0)
            line += f"\nNobody online for {idle_min} min — auto-stop in about {left} min."
        else:
            line += f"\nNobody online; auto-stop starts counting on the next check (every 5 min, stops after {IDLE_MINUTES} min empty)."
    return line


def cmd_start():
    inst = instance()
    st = state_of(inst)
    if st == "running":
        return f"Already running. Join at `{SERVER_IP}:{GAME_PORT}`."
    if st == "pending":
        return "Already starting — give it about two minutes."
    if st == "stopping":
        return "It's still shutting down; try again in a minute."
    if st != "stopped":
        return f"Instance is in state `{st}`; can't start it from here."
    ec2.start_instances(InstanceIds=[INSTANCE_ID])
    return (
        f"Starting the server. It takes about two minutes to boot and register with Steam; "
        f"then join at `{SERVER_IP}:{GAME_PORT}`."
    )


def cmd_stop(force):
    inst = instance()
    st = state_of(inst)
    if st in ("stopped", "stopping"):
        return f"Server is already **{st}**."
    if st != "running":
        return f"Instance is in state `{st}`; wait for it to settle."
    info = a2s_info()
    if info is None and not force:
        return (
            "Can't tell how many players are online (the game isn't answering queries). "
            "Not stopping. Use `/valheim stop force:True` if you're sure nobody's on."
        )
    players = info[1] if info else 0
    if players > 0 and not force:
        return (
            f"{players} player(s) are online. Not stopping. "
            f"Use `/valheim stop force:True` if you really mean it."
        )
    ec2.stop_instances(InstanceIds=[INSTANCE_ID])
    return "Stopping the server. The world saves on shutdown and a backup is uploaded to S3."


def handle_discord(event):
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        import base64
        body = base64.b64decode(body).decode()

    if not verify(event, body):
        return respond(401, {"error": "invalid request signature"})

    interaction = json.loads(body)
    itype = interaction.get("type")

    if itype == 1:  # PING — Discord uses this to validate the endpoint URL
        return respond(200, {"type": 1})

    if DISCORD_GUILD_ID and interaction.get("guild_id") != DISCORD_GUILD_ID:
        return message("This bot only works in its home server.")

    if itype != 2:
        return message("Unsupported interaction type.")

    data = interaction.get("data", {})
    if data.get("name") != "valheim":
        return message("Unknown command.")

    sub = (data.get("options") or [{}])[0]
    name = sub.get("name")
    opts = {o["name"]: o.get("value") for o in (sub.get("options") or [])}

    try:
        if name == "status":
            return message(cmd_status())
        if name == "start":
            return message(cmd_start())
        if name == "stop":
            return message(cmd_stop(bool(opts.get("force", False))))
        return message(f"Unknown subcommand `{name}`.")
    except Exception as e:  # keep Discord's 3s window happy with *some* answer
        print(f"error handling /valheim {name}: {e!r}")
        return message(f"Something went wrong talking to AWS: `{type(e).__name__}`.")


# --------------------------------------------------------------------------
def lambda_handler(event, context):
    if isinstance(event, dict) and event.get("source") == "valheim.idle-check":
        result = idle_check()
        print(json.dumps(result))
        return result
    return handle_discord(event)
