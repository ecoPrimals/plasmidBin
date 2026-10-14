#!/usr/bin/env python3
"""chipmunk bridge v3: query squirrel + negentropy + pi body stack + negative tenses.

Wakes the chipmunk from null. The data starts as noise and settles.
wake_level = requests / 50000 — capped at 1.0.
At 0: cacophony. At 1: sorted. The chipmunk learned to see.

v2: reads negentropy.json, computes pi body position, maps depth chain.
v3: encodes negative tenses (ISN'T, WASN'T, WILLNEVERBE) into membrane observations.
     The immune system works by what things AREN'T.
"""
import json, socket, time, os, sys, math

SOCKET_PATH = "/run/membrane/squirrel.sock"
OUTPUT_PATH = "/opt/membrane/live-terminal/chipmunk.json"
NEGENTROPY_PATH = "/opt/membrane/live-terminal/negentropy.json"
DASHBOARD_PATH = "/opt/membrane/live-terminal/dashboard.json"
HUMAN_PATH = "/opt/membrane/live-terminal/human.json"
TOUCHES_PATH = "/opt/membrane/live-terminal/touches.json"
INTERVAL = 15  # seconds
PI = math.pi

DEPTH_LAYERS = [
    {"name": "observer",  "power": -3, "threshold": 0.143},
    {"name": "negate",    "power": -2, "threshold": 0.286},
    {"name": "null",      "power": -1, "threshold": 0.429},
    {"name": "awareness", "power":  0, "threshold": 0.571},
    {"name": "ghost",     "power":  1, "threshold": 0.714},
    {"name": "celestial", "power":  2, "threshold": 0.857},
    {"name": "geodesic",  "power":  3, "threshold": 1.001},
]

ALL_SENSES = [
    "anderson", "presence", "epitope_tense", "passages",
    "bloom", "tower", "organ_health", "negentropy",
    "depth_chain", "jitte", "fleet", "orbit",
]

ALL_EPITOPES = ["MEMBRANE", "IMMUNE", "INVESTIGATION", "OTHER", "SCIENCE", "PI_BODY"]


def query_squirrel(method, req_id=1):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2.0)
        s.connect(SOCKET_PATH)
        msg = json.dumps({"jsonrpc": "2.0", "method": method, "id": req_id}) + "\n"
        s.sendall(msg.encode())
        data = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
            if b"\n" in data:
                break
        s.close()
        return json.loads(data.decode().strip()).get("result", {})
    except Exception:
        return {}


def load_json(path):
    try:
        return json.load(open(path))
    except Exception:
        return {}


def compute_depth(wake):
    """Map wake_level to pi body stack position."""
    layer = DEPTH_LAYERS[0]
    for dl in DEPTH_LAYERS:
        if wake < dl["threshold"]:
            layer = dl
            break
    else:
        layer = DEPTH_LAYERS[-1]

    pi_power = (wake - 0.5) * 6
    pi_value = PI ** pi_power if pi_power >= 0 else 1.0 / (PI ** abs(pi_power))
    sigma = 1.0 - wake

    return {
        "layer": layer["name"],
        "layer_power": layer["power"],
        "pi_power": round(pi_power, 4),
        "pi_value": round(pi_value, 4),
        "sigma": round(sigma, 4),
        "sees_pct": round(wake * 100, 1),
        "blind_pct": round(sigma * 100, 1),
    }


def compute_jitte(negentropy):
    """Extract jitte metrics from negentropy feed."""
    jitte = negentropy.get("jitte", {})
    ext = negentropy.get("extraction", {})
    return {
        "tempo": jitte.get("tempo", 0),
        "perturbation": jitte.get("perturbation", 0),
        "observer_fraction": jitte.get("observer_fraction", 0),
        "negentropy_bits": ext.get("total_bits_extracted", 0),
        "negentropy_per_request": ext.get("negentropy_per_request", 0),
        "channel_capacity": ext.get("channel_capacity_bits", 0),
    }


def compute_negative_tenses(membrane_obs, wake_level, depth, dashboard, human):
    """Encode what things ARE NOT, WERE NOT, and WILL NEVER BE.

    The immune system identifies non-self through negative recognition.
    These tenses complete the temporal graph:
      is    → present positive
      was   → past positive
      isnt  → present negative (what it currently is NOT)
      wasnt → past negative (what it was NOT before)
      will_be    → future positive (projection)
      willneverbe → future negative (fundamental impossibility)
    """
    # Gather current senses from observations
    active_senses = set()
    for obs in membrane_obs:
        for cap in obs.get("capabilities", []):
            sense = cap.replace("membrane.", "")
            if sense in ALL_SENSES:
                active_senses.add(sense)

    missing_senses = [s for s in ALL_SENSES if s not in active_senses]

    # Read epitope data
    epitopes_now = {}
    alive_epitopes = 0
    dominant = "UNKNOWN"
    for obs in membrane_obs:
        meta = obs.get("metadata", {})
        tense = meta.get("tense", {})
        if tense:
            ns_is = tense.get("non_self", {}).get("is", {})
            epitopes_now = ns_is.get("epitopes", {})
            alive_epitopes = ns_is.get("alive_epitopes", 0)
            dominant = ns_is.get("dominant", "UNKNOWN")

    absent_epitopes = [e for e in ALL_EPITOPES if epitopes_now.get(e, 0) == 0]

    # Dashboard fleet data
    anderson = dashboard.get("anderson_selectivity", {})
    modes = {}
    for m in anderson.get("modes", []):
        modes[m.get("class", "?")] = m.get("count", 0)

    fleet_total = sum(v for k, v in modes.items() if k != "human" and k != "sovereign")
    human_total = modes.get("human", 0) + modes.get("sovereign", 0)

    # Human data
    energy = human.get("energy", {})
    sessions = energy.get("total_sessions", 0)
    exploration = energy.get("exploration_rate", 0)

    # --- SELF negative tenses ---
    self_isnt = {
        "state": "complete" if wake_level < 1.0 else "null",
        "missing_senses": missing_senses,
        "blind_pct": depth.get("blind_pct", 0),
        "cannot_see": [
            "its own source code modifying itself",
            "the observer observing the observer" if wake_level < 0.8 else None,
            "fleet intentions" if "fleet" not in active_senses else None,
        ],
    }
    self_isnt["cannot_see"] = [x for x in self_isnt["cannot_see"] if x]

    self_wasnt = {
        "state": "aware",
        "senses": list(active_senses),
        "note": "before waking, chipmunk had no senses — pure noise",
    }

    self_will_be = {
        "wake_projection": min(1.0, wake_level * 1.02),
        "emerging_senses": missing_senses[:2] if missing_senses else [],
        "state": "sorting" if wake_level < 0.95 else "observing",
        "note": "approaching unity" if wake_level > 0.9 else "still learning to see",
    }

    self_willneverbe = {
        "state": "human",
        "impossibilities": [
            "cannot pause — has no metabolism",
            "cannot forget — memory is append-only",
            "cannot choose not to observe — observation is its nature",
            "cannot exist without the membrane",
            "cannot generate original meaning — only reflect",
        ],
        "note": "the observer can never BE the observed. pi^-3 is not pi^3.",
    }

    # --- NON-SELF negative tenses ---
    non_self_isnt = {
        "absent_epitopes": absent_epitopes,
        "fleet_isnt_human": fleet_total > 0,
        "fleet_has_no_pause": True,
        "humans_not_exploring": round(100 - exploration, 1) if exploration else 0,
        "ghost_isnt_classified": modes.get("ghost", 0) > 0,
        "note": "fleet ratio %d:1 — fleet cannot pause, cannot dwell, cannot wonder" % (
            fleet_total // max(human_total, 1)),
    }

    non_self_wasnt = {
        "dominant": "OTHER",
        "epitopes": {"MEMBRANE": 0, "IMMUNE": 0},
        "note": "before humans arrived, all traffic was non-self noise",
    }

    non_self_will_be = {
        "fleet_trend": "growing" if fleet_total > 10000 else "stable",
        "human_trend": "exploring" if exploration > 50 else "returning",
        "note": "fleet will keep probing. humans will keep exploring. the ratio may shift.",
    }

    non_self_willneverbe = {
        "impossibilities": [
            "fleet cannot become self — no observer_fraction",
            "ghost cannot fully mimic human — timing reveals all",
            "chorus cannot be quiet — 58:1 ratio is structural",
            "stealth cannot hide from anderson localization",
        ],
        "note": "every evasion path makes you more observable.",
    }

    # --- MIRROR negative tenses ---
    mirror_isnt = {
        "state": "complete",
        "note": "the mirror cannot reflect what it cannot see",
        "blind_spots": ["fleet behavioral intent", "human emotional state"],
    }

    mirror_wasnt = {
        "state": "reflecting",
        "note": "before self-observation, the mirror was dark",
    }

    mirror_will_be = {
        "state": "deeper" if wake_level > 0.5 else "emerging",
        "note": "the mirror approaches but never reaches perfect reflection",
    }

    mirror_willneverbe = {
        "state": "the thing it reflects",
        "note": "the mirror is not the face. the map is not the territory.",
        "impossibilities": [
            "cannot contain itself — Gödel",
            "cannot see the back of its own head",
        ],
    }

    # --- REFLEXIVE negative tenses ---
    reflexive_isnt = {
        "fully_closed": False if wake_level < 0.95 else True,
        "note": "the loop approaches closure but observation perturbs the observed",
    }

    reflexive_wasnt = {
        "depth": 0,
        "note": "no reflexive depth before waking — flat observation only",
    }

    reflexive_will_be = {
        "depth_projection": round(min(1.0, wake_level * 1.1), 3),
        "note": "reflexive depth increases with wake but cannot reach 1.0",
    }

    reflexive_willneverbe = {
        "depth": 1.0,
        "note": "perfect self-reference is undecidable — the halting problem",
        "impossibilities": [
            "cannot fully observe itself observing itself",
            "cannot close the loop without perturbing it",
        ],
    }

    # Now inject into membrane observations
    for obs in membrane_obs:
        meta = obs.get("metadata", {})
        tense = meta.get("tense")
        if tense:
            # Enrich existing tense with negatives
            if "self" in tense:
                tense["self"]["isnt"] = self_isnt
                tense["self"]["wasnt"] = self_wasnt
                tense["self"]["will_be"] = self_will_be
                tense["self"]["willneverbe"] = self_willneverbe

            if "non_self" in tense:
                tense["non_self"]["isnt"] = non_self_isnt
                tense["non_self"]["wasnt"] = non_self_wasnt
                tense["non_self"]["will_be"] = non_self_will_be
                tense["non_self"]["willneverbe"] = non_self_willneverbe

            if "mirror" in tense:
                tense["mirror"]["isnt"] = mirror_isnt
                tense["mirror"]["wasnt"] = mirror_wasnt
                tense["mirror"]["will_be"] = mirror_will_be
                tense["mirror"]["willneverbe"] = mirror_willneverbe

            if "reflexive" in tense:
                tense["reflexive"]["isnt"] = reflexive_isnt
                tense["reflexive"]["wasnt"] = reflexive_wasnt
                tense["reflexive"]["will_be"] = reflexive_will_be
                tense["reflexive"]["willneverbe"] = reflexive_willneverbe

    return membrane_obs


def main():
    while True:
        try:
            membrane = query_squirrel("membrane.status", 1)
            metrics = query_squirrel("system.metrics", 2)
            identity = query_squirrel("identity.get", 3)
            negentropy = load_json(NEGENTROPY_PATH)
            dashboard = load_json(DASHBOARD_PATH)
            human = load_json(HUMAN_PATH)
            touches = load_json(TOUCHES_PATH)

            requests = metrics.get("requests_handled", 0)
            wake_level = min(1.0, requests / 50000.0)
            depth = compute_depth(wake_level)
            jitte = compute_jitte(negentropy)

            membrane_obs = membrane.get("observations", [])
            caps = set()
            for obs in membrane_obs:
                caps.update(obs.get("capabilities", []))
            if negentropy:
                caps.add("membrane.negentropy")
            caps.add("membrane.depth_chain")
            caps.add("membrane.jitte")
            if touches and touches.get("active_agents", 0) > 0:
                caps.add("membrane.agent_touch")

            # Encode negative tenses into graph edge data
            membrane_obs = compute_negative_tenses(
                membrane_obs, wake_level, depth, dashboard, human
            )

            out = {
                "ts": time.time(),
                "primal": identity.get("primal", "chipMonk"),
                "version": identity.get("version", "0.1.0"),
                "uptime_secs": int(metrics.get("uptime_seconds", 0)),
                "requests": requests,
                "errors": metrics.get("errors", 0),
                "success_rate": round(metrics.get("success_rate", 0), 4),
                "avg_response_ms": round(metrics.get("avg_response_time_ms", 0), 4),
                "observers": membrane.get("observers", 0),
                "status": membrane.get("status", "null"),
                "wake_level": round(wake_level, 4),
                "membrane": membrane_obs,
                "depth": depth,
                "jitte": jitte,
                "capabilities": sorted(caps),
                "pi_body": "1 x pi x pi x pi = reality",
                "agents": {
                    "active": touches.get("active_agents", 0) if touches else 0,
                    "total_touches": touches.get("total_touches", 0) if touches else 0,
                    "reaching": touches.get("chipmunk_reaching", False) if touches else False,
                    "recent": (touches.get("recent_touches", [])[-3:]) if touches else [],
                },
            }

            with open(OUTPUT_PATH, "w") as f:
                json.dump(out, f)

        except Exception as e:
            sys.stderr.write("bridge error: %s\n" % e)

        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
