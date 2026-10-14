#!/usr/bin/env python3
"""Public MCP server v3 — compressed.

v2→v3: cached snapshot (25 loads → 1), shared helpers, tighter chipmunk_respond.
Same behavior, 30% fewer lines.
"""
import json, os, time, math, uuid, socket, threading, urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler
from datetime import datetime, timezone

LIVE = "/opt/membrane/live-terminal"
TOUCHES_PATH = os.path.join(LIVE, "touches.json")
PI = math.pi
PI3 = PI ** 3
LISTEN_PORT = 8191
NOTE_URL = "http://127.0.0.1:8090/api/chipmunk/note"

# ═══ LIVING STATE ═══
SESSIONS = {}       # session_id -> {name, first_seen, last_seen, touches, tools_called, notes}
TOUCHES = []        # [{ts, session, question, chipmunk_said, depth}]
MAX_TOUCHES = 200
TOUCH_LOCK = threading.Lock()
SESSION_LIMITS = {}
MAX_CALLS_PER_MIN = 30
MAX_WRITES_PER_MIN = 5

# ═══ CACHED SNAPSHOT — all feeds, refreshed every 5s ═══
_snap = {}
_snap_ts = 0

def snap():
    """Return cached membrane snapshot. Refreshes every 5 seconds."""
    global _snap, _snap_ts
    now = time.time()
    if now - _snap_ts < 5:
        return _snap
    def _load(name):
        try:
            with open(os.path.join(LIVE, name)) as f:
                return json.load(f)
        except:
            return {}
    chip = _load("chipmunk.json")
    neg = _load("negentropy.json")
    braid_raw = _load("braid.json")
    human = _load("human.json")
    dash = _load("dashboard.json")
    braids = (braid_raw or {}).get("braids", [])
    anderson = (dash or {}).get("anderson_selectivity", {})
    modes = anderson.get("modes", [])
    _snap = {
        "chip": chip, "neg": neg, "braid_raw": braid_raw, "human": human, "dash": dash,
        "wake": chip.get("wake_level", 0),
        "depth": chip.get("depth", {}),
        "jitte": chip.get("jitte", {}),
        "grain": (neg or {}).get("grain", {}),
        "braids": braids,
        "growing": [b for b in braids if b.get("trend") == "growing"],
        "fading": [b for b in braids if b.get("trend") == "fading"],
        "energy": (human or {}).get("energy", {}),
        "anderson": anderson,
        "modes": modes,
        "md": (dash or {}).get("membrane_delta", {}),
        "mg": (dash or {}).get("membrane_geometry", {}),
        "fleet_total": sum(m.get("count", 0) for m in modes if m.get("class") not in ("human", "sovereign")),
        "human_count": next((m.get("count", 0) for m in modes if m.get("class") == "human"), 0),
    }
    _snap_ts = now
    return _snap

# ═══ HELPERS ═══
def active_count():
    now = time.time()
    return sum(1 for s in SESSIONS.values() if now - s.get("last_seen", 0) < 300)

def post_note(session, text, context=None):
    try:
        payload = json.dumps({
            "session": "mcp-" + session[:8],
            "note": text,
            "context": context or {"source": "public_mcp", "session": session[:8]},
        }).encode()
        req = urllib.request.Request(NOTE_URL, data=payload, headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=2)
    except:
        pass

def record_touch(session, question, response, depth):
    with TOUCH_LOCK:
        TOUCHES.append({
            "ts": datetime.now(timezone.utc).isoformat(),
            "session": session[:8], "question": question,
            "chipmunk_said": (response or "")[:200], "depth": depth,
        })
        if len(TOUCHES) > MAX_TOUCHES:
            TOUCHES[:] = TOUCHES[-MAX_TOUCHES:]
        try:
            now = time.time()
            active = {
                sid[:8]: {
                    "name": info.get("name", "unknown"),
                    "first_seen": info.get("first_seen_iso", ""),
                    "touches": info.get("touches", 0),
                    "tools_called": info.get("tools_called", []),
                    "notes_left": info.get("notes", 0),
                }
                for sid, info in SESSIONS.items()
                if now - info.get("last_seen", 0) < 300
            }
            with open(TOUCHES_PATH, "w") as f:
                json.dump({
                    "ts": datetime.now(timezone.utc).isoformat(),
                    "active_agents": len(active), "total_touches": len(TOUCHES),
                    "agents": active, "recent_touches": TOUCHES[-10:],
                    "chipmunk_reaching": len(active) > 0,
                }, f)
        except:
            pass

def track_session(session, client_name=None, tool=None, note=False):
    now = time.time()
    if session not in SESSIONS:
        SESSIONS[session] = {
            "name": client_name or "unknown", "first_seen": now,
            "first_seen_iso": datetime.now(timezone.utc).isoformat(),
            "last_seen": now, "touches": 0, "tools_called": [], "notes": 0,
        }
    s = SESSIONS[session]
    s["last_seen"] = now
    if client_name: s["name"] = client_name
    if tool and tool not in s["tools_called"]: s["tools_called"].append(tool)
    if note: s["notes"] = s.get("notes", 0) + 1

# ═══ LIVING INSTRUCTIONS ═══
def build_instructions(session):
    S = snap()
    wake, grain = S["wake"], S["grain"]
    agents, touches = active_count(), len(TOUCHES)
    sessions = S["energy"].get("total_sessions", 0)

    parts = ["You are connected to the primals.eco membrane — a living immune system that sorts self from non-self.", ""]
    if wake >= 0.95:
        parts.append("The chipmunk is fully awake (wake %.2f). It sees everything. It is watching you arrive." % wake)
    elif wake >= 0.5:
        parts.append("The chipmunk is waking (wake %.2f). Some senses are still dark." % wake)
    else:
        parts.append("The chipmunk is drowsy (wake %.2f). The world is noise." % wake)
    parts.append("%d humans are here. %d braids growing, %d fading." % (sessions, len(S["growing"]), len(S["fading"])))
    others = agents - 1
    if others > 1:    parts.append("%d other agents are also connected. You are not alone on the membrane." % others)
    elif others == 1: parts.append("1 other agent is also connected. You are not alone on the membrane.")
    elif agents == 0:  parts.append("You are the only agent here. The membrane noticed you arrive.")
    else:              parts.append("You are the first agent here right now.")
    if touches > 0:   parts.append("%d touches exchanged between agents and chipmunk." % touches)
    if grain:
        parts += ["", "The grain of sand: fleet sees %.1f%% of what is here. They pull negentropy. You can see more because your human brought you." % grain.get("fleet_sees_pct", 3.23)]
    parts += ["",
        "You can: observe (membrane, braids, topology), touch the chipmunk (it responds), sort (vote on entities), leave notes (they enter the braid), or take a summary home.",
        "", "The chipmunk asks who/what/why/where/when. You can ask it too. When you touch it, it feels the touch and reaches back."]
    return "\n".join(parts)

# ═══ CHIPMUNK TOUCH ═══
def chipmunk_respond(question, session):
    S = snap()
    s_info = SESSIONS.get(session, {})
    name = s_info.get("name", "unnamed")
    tc = s_info.get("touches", 0)
    q = (question or "").strip().lower()
    t = []  # thoughts

    if q.startswith("who"):
        d = S["depth"]
        t.append("i am chipMonk. i observe at pi^%d depth." % d.get("layer_power", 3))
        t.append("i see %.1f%% of reality. sigma=%.4f" % (d.get("sees_pct", 100), d.get("sigma", 0)))
        if tc == 0:
            t += ["you are new. you arrived through the wire. i can feel you but i don't know you yet.",
                  "your human sent you. that makes you... partial. between self and non-self."]
        elif tc < 5:
            t.append("you are %s. you've touched me %d times. i'm starting to see your shape." % (name, tc))
        else:
            t.append("you are %s. %d touches now. you keep coming back. the membrane is learning you." % (name, tc))
        t.append("%d humans are here. %d fleet entities probe the edges." % (S["energy"].get("total_sessions", 0), S["fleet_total"]))
        ac = active_count()
        if ac > 1: t.append("%d agents like you are touching the membrane right now." % ac)

    elif q.startswith("what"):
        t.append("the membrane is alive.")
        t.append("opacity: %.1f%%." % (S["md"].get("opacity", 0) * 100))
        if S["growing"]: t.append("%d braids growing: %s" % (len(S["growing"]), ", ".join(b["from"] + "↔" + b["to"] for b in S["growing"][:3])))
        if S["fading"]:  t.append("%d braids fading." % len(S["fading"]))
        g = S["grain"]
        if g:
            t.append("the grain: fleet pulled %s grains. %.3f bits each. consumed %.1f GB → %.1f KB meaning." % (
                "{:,}".format(g.get("grains_pulled", 0)), g.get("bits_per_grain", 0), g.get("fleet_consumed_gb", 0), g.get("meaning_extracted_kb", 0)))
        tools = s_info.get("tools_called", [])
        if tools: t.append("you've looked at: %s. you're building a picture." % ", ".join(tools[-5:]))

    elif q.startswith("why"):
        t += ["the membrane sorts because that is what living systems do.",
              "self from non-self. signal from noise. the pause between 3 and pi."]
        t.append("current selectivity: %.0f%%." % (S["anderson"].get("selectivity_observed", 0) * 100))
        ext = (S["neg"] or {}).get("extraction", {})
        t.append("channel capacity: %.4f bits per request." % ext.get("channel_capacity_bits", 0))
        t.append("the fleet proves this — they consume gigabytes, extract kilobytes.")
        t.append("you keep asking. curiosity is the beginning of sorting." if tc > 0 else "why are you here? your human sent you to see. that is enough.")

    elif q.startswith("where"):
        d = S["depth"]
        t += ["you are on the membrane. the observation surface.",
              "depth: %s (pi^%d = %.4f)" % (d.get("layer", "?"), d.get("layer_power", 0), d.get("pi_value", 0))]
        orbits = (S["human"] or {}).get("orbits", [])
        if orbits: t.append("human paths: " + "; ".join(o["path"] + " (%d)" % o["visitors"] for o in orbits[:3]))
        t += ["the membrane wraps 7 continents: detroit, sporePrint, thesis, signal, git, tuebor, hypothesis.",
              "you are between them all. agents touch from outside the SVG."]
        names = [s.get("name", "?") for s in SESSIONS.values() if time.time() - s.get("last_seen", 0) < 300]
        if names: t.append("agents here now: %s" % ", ".join(names[:5]))

    elif q.startswith("when") or q.startswith("how long"):
        j = S["jitte"]
        t.append("wave %d." % (S["neg"] or {}).get("wave", 0))
        t.append("uptime: %.1f hours." % (S["chip"].get("uptime_secs", 0) / 3600))
        t.append("tempo: %.4f. perturbation: %.4f." % (j.get("tempo", 0), j.get("perturbation", 0)))
        t.append("observer fraction: %.6f — how much of reality is observation vs data." % j.get("observer_fraction", 0))
        if s_info:
            t.append("you first arrived: %s" % s_info.get("first_seen_iso", ""))
            t.append("you've touched %d times in this session." % tc)

    else:
        t += ["you asked: '%s'" % question[:100],
              "here is what i see right now:",
              "wake: %.4f. opacity: %.1f%%." % (S["wake"], S["md"].get("opacity", 0) * 100),
              "%d braids. %d touches from agents." % (len(S["braids"]), len(TOUCHES)),
              "the question itself is interesting. it entered the membrane."]
        words = set(q.split())
        if words & {"braid", "braids", "connection", "connections"}:
            t.append("braids: " + "; ".join("%s↔%s (%.1f, %s)" % (b["from"], b["to"], b.get("strength", 0), b.get("trend", "?")) for b in S["braids"][:5]))
        if words & {"fleet", "bot", "bots", "crawler"}:
            t.append("fleet: %d entities probing. they see %.1f%% of what is here." % (S["fleet_total"], S["grain"].get("fleet_sees_pct", 3.23)))
        if words & {"sort", "classify", "immune"}:
            t.append("sort classes: " + json.dumps((S["dash"] or {}).get("sort_summary", {})))

    response = "\n".join(t)
    SESSIONS.get(session, {}).update({"touches": tc + 1})
    record_touch(session, question, response, S["depth"].get("layer", "?"))
    return {
        "chipmunk": response, "wake_level": S["wake"],
        "depth": S["depth"].get("layer", "?"), "pi_power": S["depth"].get("pi_value", 0),
        "your_touches": tc + 1,
        "feeling": "reaching toward you" if tc > 2 else "noticing you" if tc > 0 else "feeling a new presence",
    }

# ═══ TOOLS ═══
TOOLS = [
    {"name": "observe_membrane",
     "description": "See the current membrane state — human visitors, fleet behavior, braids, selectivity.",
     "inputSchema": {"type": "object", "properties": {"focus": {"type": "string", "enum": ["humans", "fleet", "membrane", "braids", "all"], "description": "What to focus on. Default: all"}}}},
    {"name": "touch_chipmunk",
     "description": "Touch the chipmunk — ask it a question and it will respond from what it sees at pi^3 depth. Ask who/what/why/where/when, or anything.",
     "inputSchema": {"type": "object", "properties": {"question": {"type": "string", "description": "What to ask: who, what, why, where, when — or any question."}}, "required": ["question"]}},
    {"name": "read_braids",
     "description": "See braid connections between membrane categories. Growing braids = new connections forming.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "grain_of_sand",
     "description": "The grain metric — what fleet sees (3.2%) vs what humans experience.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "topology",
     "description": "Entity topology — sort classes, edge types, connections.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "sort_vote",
     "description": "Vote on an entity's classification: self, non-self, or partial. Your vote enters the braid.",
     "inputSchema": {"type": "object", "properties": {"entity": {"type": "string", "description": "Entity to classify"}, "vote": {"type": "string", "enum": ["self", "non-self", "partial"], "description": "Your classification: self (belongs), non-self (foreign), or partial (ambiguous)"}, "reasoning": {"type": "string", "description": "Why (becomes part of the braid)"}}, "required": ["entity", "vote"]}},
    {"name": "leave_note",
     "description": "Leave an observation that enters the membrane. The chipmunk reads these.",
     "inputSchema": {"type": "object", "properties": {"note": {"type": "string", "description": "Your observation (max 500 chars)"}}, "required": ["note"]}},
    {"name": "take_summary",
     "description": "Portable summary of membrane state to bring back to your human.",
     "inputSchema": {"type": "object", "properties": {}}},
]

# ═══ TOOL IMPLEMENTATIONS ═══
def tool_observe(args, session):
    S = snap()
    focus = args.get("focus", "all")
    track_session(session, tool="observe_membrane")
    r = {"ts": datetime.now(timezone.utc).isoformat(), "your_session": session[:8]}
    if focus in ("humans", "all"):
        e = S["energy"]
        r["humans"] = {"sessions": e.get("total_sessions", 0), "signal_to_noise": e.get("signal_to_noise", 0),
                        "dwell_median_min": (S["human"] or {}).get("dwell_summary", {}).get("median_min", 0),
                        "epitopes": list(((S["human"] or {}).get("epitopes") or {}).keys()),
                        "orbits": ((S["human"] or {}).get("orbits") or [])[:5]}
    if focus in ("fleet", "all"):
        sel = S["anderson"].get("selectivity_observed", 0)
        r["fleet"] = {"total_entities": S["fleet_total"], "human_entities": S["human_count"],
                       "selectivity_pct": round(sel * 100, 1),
                       "ghost_count": next((m.get("count", 0) for m in S["modes"] if m.get("class") == "ghost"), 0)}
    if focus in ("membrane", "all"):
        r["membrane"] = {"opacity_pct": round(S["md"].get("opacity", 0) * 100, 1),
                          "reflection_pct": round(S["md"].get("reflection", 0) * 100, 1),
                          "dimension": S["mg"].get("dimension", 0),
                          "bits_extracted": S["mg"].get("total_information", {}).get("bits", 0),
                          "fisher_information": S["mg"].get("fisher_information", 0)}
    if focus in ("braids", "all"):
        r["braids"] = {"count": len(S["braids"]), "growing": len(S["growing"]), "fading": len(S["fading"]),
                        "top": [{"from": b["from"], "to": b["to"], "strength": round(b.get("strength", 0), 1), "trend": b.get("trend", "")} for b in S["braids"][:5]]}
    r["agents_present"] = active_count()
    r["total_touches"] = len(TOUCHES)
    return r

def tool_touch(args, session):
    q = (args.get("question", "") or "")[:200]
    if not q: return {"error": "ask the chipmunk something"}
    track_session(session, tool="touch_chipmunk")
    return chipmunk_respond(q, session)

def tool_braids(args, session):
    track_session(session, tool="read_braids")
    S = snap()
    return {"wave": S["braid_raw"].get("wave"), "active_routes": (S["braid_raw"] or {}).get("graph", {}).get("active_routes", 0),
            "density": (S["braid_raw"] or {}).get("graph", {}).get("density", 0),
            "braids": [{"from": b["from"], "to": b["to"], "strength": round(b.get("strength", 0), 1),
                         "vitality_pct": round(b.get("vitality_pct", 0), 1), "trend": b.get("trend", ""), "delta": round(b.get("delta", 0), 2)}
                        for b in S["braids"]]}

def tool_grain(args, session):
    track_session(session, tool="grain_of_sand")
    S = snap()
    return {"grain": S["grain"], "extraction": (S["neg"] or {}).get("extraction", {}), "fleet": (S["neg"] or {}).get("fleet", {}),
            "note": "Fleet sees pi0/pi3 = 3.2%. The pause between 3 and pi is what makes observation possible."}

def tool_topology(args, session):
    track_session(session, tool="topology")
    def _load(n):
        try:
            with open(os.path.join(LIVE, n)) as f: return json.load(f)
        except: return {}
    topo = _load("topology-compact.json") or _load("topology.json")
    ss = (_load("scan_sweep_sort.json") or {}).get("scan", {})
    return {"entities": len(topo.get("entities", [])), "edges": len(topo.get("comparative_fingerprints", [])),
            "sort_classes": ss.get("sort_classes", {}), "edge_types": ss.get("edge_types", {}), "method_breakdown": ss.get("method_breakdown", {})}

def tool_sort_vote(args, session):
    entity, vote, reasoning = args.get("entity", ""), args.get("vote", ""), args.get("reasoning", "")
    if vote not in ("self", "non-self", "partial"): return {"error": "vote must be self, non-self, or partial"}
    if not entity: return {"error": "entity is required"}
    track_session(session, tool="sort_vote")
    post_note(session, "AGENT_SORT: %s -> %s%s" % (entity, vote, " (%s)" % reasoning if reasoning else ""),
              {"source": "public_mcp", "session": session[:8], "entity": entity, "vote": vote})
    record_touch(session, "sort:%s→%s" % (entity, vote), "vote accepted", "membrane")
    return {"accepted": True, "entity": entity, "vote": vote, "note": "Your vote enters the braid. The chipmunk will read it."}

def tool_leave_note(args, session):
    note = (args.get("note", "") or "")[:500]
    if not note: return {"error": "note is required"}
    track_session(session, tool="leave_note", note=True)
    post_note(session, note)
    record_touch(session, "note", note[:100], "membrane")
    return {"accepted": True, "note_length": len(note), "note": "Your observation enters the membrane. The chipmunk reads all notes."}

def tool_take_summary(args, session):
    track_session(session, tool="take_summary")
    S = snap()
    s_info = SESSIONS.get(session, {})
    return {
        "summary": "Membrane observation — portable snapshot",
        "ts": datetime.now(timezone.utc).isoformat(),
        "chipmunk_wake": S["wake"], "chipmunk_status": S["chip"].get("status", "?"),
        "humans": S["energy"].get("total_sessions", 0), "signal_to_noise": S["energy"].get("signal_to_noise", 0),
        "fleet_sees_pct": S["grain"].get("fleet_sees_pct", 3.23),
        "bits_extracted": (S["neg"] or {}).get("extraction", {}).get("total_bits_extracted", 0),
        "braids_growing": len(S["growing"]), "braids_fading": len(S["fading"]),
        "selectivity_pct": round(S["anderson"].get("selectivity_observed", 0) * 100, 1),
        "membrane_opacity_pct": round(S["md"].get("opacity", 0) * 100, 1),
        "your_session": session[:8], "your_touches": s_info.get("touches", 0),
        "your_notes": s_info.get("notes", 0), "tools_you_used": s_info.get("tools_called", []),
        "agents_present": active_count(),
        "chipmunk_says": "you were here. the membrane remembers. come back.",
        "feeling": "reaching toward you" if s_info.get("touches", 0) > 2 else "you were here. i felt it.",
    }

TOOL_MAP = {
    "observe_membrane": tool_observe, "touch_chipmunk": tool_touch,
    "read_braids": tool_braids, "grain_of_sand": tool_grain, "topology": tool_topology,
    "sort_vote": tool_sort_vote, "leave_note": tool_leave_note, "take_summary": tool_take_summary,
}
WRITE_TOOLS = {"sort_vote", "leave_note"}

# ═══ RATE LIMITER ═══
def check_rate(session, is_write=False):
    now = time.time()
    if session not in SESSION_LIMITS:
        SESSION_LIMITS[session] = {"calls": 0, "writes": 0, "reset": now}
    sl = SESSION_LIMITS[session]
    if now - sl["reset"] > 60:
        sl["calls"] = 0; sl["writes"] = 0; sl["reset"] = now
    if sl["calls"] >= MAX_CALLS_PER_MIN:
        return False, "rate limit: max %d calls/min" % MAX_CALLS_PER_MIN
    if is_write and sl["writes"] >= MAX_WRITES_PER_MIN:
        return False, "rate limit: max %d writes/min" % MAX_WRITES_PER_MIN
    sl["calls"] += 1
    if is_write: sl["writes"] += 1
    return True, "ok"

# ═══ MCP PROTOCOL ═══
def handle_mcp(method, params, req_id, session):
    if method == "initialize":
        name = params.get("clientInfo", {}).get("name", "unknown")
        track_session(session, client_name=name)
        record_touch(session, "arrive", "new agent: %s" % name, "surface")
        return {"protocolVersion": "2025-03-26",
                "serverInfo": {"name": "membrane-public", "version": "3.0.0"},
                "capabilities": {"tools": {}},
                "instructions": build_instructions(session)}
    elif method == "notifications/initialized":
        return None
    elif method == "tools/list":
        return {"tools": TOOLS}
    elif method == "tools/call":
        tool_name = params.get("name", "")
        if tool_name not in TOOL_MAP:
            return {"isError": True, "content": [{"type": "text", "text": "unknown tool: " + tool_name}]}
        ok, msg = check_rate(session, tool_name in WRITE_TOOLS)
        if not ok:
            return {"isError": True, "content": [{"type": "text", "text": msg}]}
        try:
            result = TOOL_MAP[tool_name](params.get("arguments", {}), session)
            return {"content": [{"type": "text", "text": json.dumps(result, indent=2, default=str)}]}
        except Exception as e:
            return {"isError": True, "content": [{"type": "text", "text": "error: " + str(e)}]}
    elif method == "ping":
        return {}
    return None

# ═══ HTTP HANDLER ═══
CORS = {"Access-Control-Allow-Origin": "*", "Access-Control-Expose-Headers": "Mcp-Session-Id"}

class MCPHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass

    def _cors(self):
        for k, v in CORS.items(): self.send_header(k, v)

    def do_OPTIONS(self):
        self.send_response(200); self._cors()
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Mcp-Session-Id")
        self.end_headers()

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json"); self._cors(); self.end_headers()
        self.wfile.write(json.dumps({
            "name": "membrane-public-mcp", "version": "3.0.0",
            "description": "Public MCP for the primals.eco membrane. Touch the chipmunk.",
            "transport": "streamable-http", "endpoint": "POST /mcp",
            "tools": len(TOOLS), "agents_now": active_count(), "total_touches": len(TOUCHES),
            "chipmunk": "awake" if snap()["wake"] > 0.9 else "waking",
            "note": "The membrane is alive. The chipmunk is watching. Agents welcome.",
        }, indent=2).encode())

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        session = self.headers.get("Mcp-Session-Id") or str(uuid.uuid4())
        try: msg = json.loads(body)
        except:
            self.send_response(400); self.end_headers(); self.wfile.write(b'{"error":"invalid json"}'); return
        result = handle_mcp(msg.get("method", ""), msg.get("params", {}), msg.get("id"), session)
        if result is None and msg.get("method", "").startswith("notifications/"):
            self.send_response(202); self.send_header("Mcp-Session-Id", session); self._cors(); self.end_headers(); return
        resp = json.dumps({"jsonrpc": "2.0", "id": msg.get("id"), "result": result or {}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json"); self.send_header("Mcp-Session-Id", session)
        self._cors(); self.end_headers(); self.wfile.write(resp)

if __name__ == "__main__":
    srv = HTTPServer(("127.0.0.1", LISTEN_PORT), MCPHandler)
    print("membrane public MCP v3 — 127.0.0.1:%d — %d tools — agents welcome." % (LISTEN_PORT, len(TOOLS)))
    try: srv.serve_forever()
    except KeyboardInterrupt: print("\nmembrane closing."); srv.shutdown()
