"""
SofaScore - Loop completo para extraer todos los partidos del Mundial 2026.
Primero obtiene todos los event_ids, luego procesa cada partido.

pip install playwright
playwright install chromium
"""

import json
import time
import os
from playwright.sync_api import sync_playwright

TOURNAMENT_ID = 16     # FIFA World Cup en SofaScore
SEASON_ID     = 58210  # Mundial 2026
OUTPUT_DIR    = "partidos_wc2026"
DELAY_ENTRE_REQUESTS = 0.5  # segundos entre requests para no ser bloqueado


# ── Helpers ──────────────────────────────────────────────────────────────────

def fetch_json(page, endpoint, referer="https://www.sofascore.com/"):
    url = f"https://www.sofascore.com{endpoint}"
    script = """
    async (args) => {
        const response = await fetch(args.url, {
            method: "GET",
            credentials: "include",
            cache: "no-store",
            headers: { "Accept": "application/json", "Referer": args.referer }
        });
        return { status: response.status, body: await response.text() };
    }
    """
    result = page.evaluate(script, {"url": url, "referer": referer})
    if result["status"] == 200:
        return json.loads(result["body"])
    print(f"  ERROR {result['status']}: {result['body'][:100]}")
    return None


def inferir_period(minuto):
    if minuto is None: return "unknown"
    if minuto <= 45:   return "1ST"
    if minuto <= 90:   return "2ND"
    if minuto <= 105:  return "ET1"
    return "ET2"


# ── Parsers ───────────────────────────────────────────────────────────────────

def parsear_incidents(data):
    if not data:
        return []
    eventos = []
    for inc in data.get("incidents", []):
        tipo = inc.get("incidentType")
        e = {
            "minute":  inc.get("time"),
            "added":   inc.get("addedTime", 0),
            "period":  inc.get("periodName") or inferir_period(inc.get("time", 0)),
            "is_home": inc.get("isHome"),
            "type":    tipo,
            "class":   inc.get("incidentClass"),
        }
        if tipo == "goal":
            e["player"]    = inc.get("player", {}).get("name")
            e["assist"]    = inc.get("assist1", {}).get("name") if inc.get("assist1") else None
            e["goal_type"] = inc.get("incidentClass")
            for a in inc.get("footballPassingNetworkAction", []):
                if a.get("eventType") == "goal":
                    e["shot_x"] = a.get("playerCoordinates", {}).get("x")
                    e["shot_y"] = a.get("playerCoordinates", {}).get("y")
        elif tipo == "card":
            e["player"] = inc.get("player", {}).get("name")
            e["reason"] = inc.get("reason")
        elif tipo == "substitution":
            e["player_in"]  = inc.get("playerIn", {}).get("name")
            e["player_out"] = inc.get("playerOut", {}).get("name")
        elif tipo == "period":
            e["text"]       = inc.get("text")
            e["home_score"] = inc.get("homeScore")
            e["away_score"] = inc.get("awayScore")
        elif tipo == "injuryTime":
            e["length"] = inc.get("length")
        elif tipo == "varDecision":
            e["player"]    = inc.get("player", {}).get("name")
            e["var_class"] = inc.get("incidentClass")
        eventos.append(e)
    return eventos


def parsear_comments(data):
    if not data:
        return {"pausas_hidratacion": [], "total_comentarios": 0,
                "tipos_disponibles": [], "todos_eventos": []}

    pausas, todos = [], []
    pausa_abierta = None
    comments = list(reversed(data.get("comments", [])))

    for c in comments:
        tipo   = c.get("type")
        minuto = c.get("time")
        texto  = c.get("text", "")
        period = c.get("periodName", "")
        todos.append({"minute": minuto, "period": period, "type": tipo, "text": texto})

        if tipo == "startDelay" and "drinks" in texto.lower():
            pausa_abierta = {"start_minute": minuto, "period": period, "type": "hydration_break"}
        elif tipo == "endDelay" and pausa_abierta:
            pausa_abierta["end_minute"] = minuto
            pausa_abierta["duration"]   = minuto - pausa_abierta["start_minute"]
            pausas.append(pausa_abierta)
            pausa_abierta = None

    return {
        "pausas_hidratacion": pausas,
        "total_comentarios":  len(todos),
        "tipos_disponibles":  list({c["type"] for c in todos}),
        "todos_eventos":      todos,
    }


def parsear_statistics(data):
    if not data:
        return {}
    result = {}
    for periodo in data.get("statistics", []):
        pname = periodo.get("period", "unknown")
        result[pname] = {}
        for grupo in periodo.get("groups", []):
            for item in grupo.get("statisticsItems", []):
                result[pname][item["name"]] = {
                    "home": item.get("home"),
                    "away": item.get("away"),
                }
    return result


# ── Paso 1: Obtener todos los event_ids ───────────────────────────────────────

def obtener_todos_los_partidos(page):

    print("Obteniendo calendario...")

    calendario = fetch_json(
        page,
        f"/api/v1/calendar/season/{SEASON_ID}/-18000/days-with-events"
    )

    if not calendario:
        return []

    ids_vistos = set()
    todos = []  

    for dia in calendario["dailySeasonEvents"]:

        fecha = dia["date"]

        print(f"Fecha {fecha} ({dia['count']} partidos)")

        data = fetch_json(
            page,
            f"/api/v1/unique-tournament/{TOURNAMENT_ID}/scheduled-events/{fecha}"
        )

        if not data:
            continue

        for p in data.get("events", []):

            if p["season"]["id"] != SEASON_ID:
                continue

            event_id = p["id"]

            if event_id in ids_vistos:
                continue

            ids_vistos.add(event_id)

            todos.append({
                "event_id": event_id,
                "home_team": p["homeTeam"]["name"],
                "away_team": p["awayTeam"]["name"],
                "home_score": p.get("homeScore", {}).get("current"),
                "away_score": p.get("awayScore", {}).get("current"),
                "status": p["status"]["description"],
                "start_timestamp": p["startTimestamp"],
                "slug": p["slug"],

                # NUEVO
                "round": p.get("roundInfo", {}).get("round"),
                "round_name": p.get("roundInfo", {}).get("name"),
                "round_slug": p.get("roundInfo", {}).get("slug"),
                "tournament": p.get("tournament"),
                "season": p.get("season"),
                "homeTeam": p.get("homeTeam"),
                "awayTeam": p.get("awayTeam"),
                "venue": p.get("venue"),

                # Incluso puedes guardar todo el evento
                "event_raw": p
            })

        time.sleep(DELAY_ENTRE_REQUESTS)

    print(f"\nTotal encontrados: {len(todos)}")

    return todos


# ── Paso 2: Procesar un partido completo ──────────────────────────────────────

def procesar_partido(page, partido_info):
    event_id  = partido_info["event_id"]
    home      = partido_info["home_team"]
    away      = partido_info["away_team"]
    slug      = partido_info.get("slug", "")
    match_url = f"https://www.sofascore.com/football/match/{slug}#id:{event_id}"

    print(f"\n  [{event_id}] {home} vs {away}")



    raw_incidents  = fetch_json(page, f"/api/v1/event/{event_id}/incidents",  match_url)
    time.sleep(DELAY_ENTRE_REQUESTS)
    raw_comments   = fetch_json(page, f"/api/v1/event/{event_id}/comments",   match_url)
    time.sleep(DELAY_ENTRE_REQUESTS)
    raw_statistics = fetch_json(page, f"/api/v1/event/{event_id}/statistics", match_url)
    time.sleep(DELAY_ENTRE_REQUESTS)

    partido = {
        **partido_info,

        #"round": raw_event.get("roundInfo", {}).get("round"),
        #"round_name": raw_event.get("roundInfo", {}).get("name"),
        #"round_slug": raw_event.get("roundInfo", {}).get("slug"),

        #"event": raw_event,

        "incidents": parsear_incidents(raw_incidents),
        "comments": parsear_comments(raw_comments),
        "statistics": parsear_statistics(raw_statistics),
    }

    pausas = partido["comments"]["pausas_hidratacion"]
    print(f"    incidents: {len(partido['incidents'])} | "
          f"comments: {partido['comments']['total_comentarios']} | "
          f"pausas_hidratacion: {len(pausas)}")

    return partido


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # Archivo de índice con todos los partidos procesados
    indice_path = os.path.join(OUTPUT_DIR, "_indice.json")

    # Cargar progreso previo si existe (para reanudar si se interrumpe)
    procesados = set()
    if os.path.exists(indice_path):
        with open(indice_path, "r") as f:
            indice = json.load(f)
            procesados = {p["event_id"] for p in indice if p.get("ok")}
        print(f"Progreso anterior encontrado: {len(procesados)} partidos ya procesados")
    else:
        indice = []

    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=False,
            args=["--disable-blink-features=AutomationControlled"]
        )
        context = browser.new_context(
            user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36",
            viewport={"width": 1280, "height": 800},
            locale="en-US",
        )
        page = context.new_page()

        # Navegar al torneo para establecer sesión
        tournament_url = f"https://www.sofascore.com/football/tournament/world/world-championship/16#id:{SEASON_ID}"
        print(f"Estableciendo sesión en: {tournament_url}")
        page.goto(tournament_url, wait_until="domcontentloaded", timeout=60000)
        page.wait_for_timeout(4000)

        # ── Paso 1: Listar todos los partidos ──
        print("\n=== PASO 1: Obteniendo lista de partidos ===")
        partidos_lista = obtener_todos_los_partidos(page)
        print(f"\nTotal partidos encontrados: {len(partidos_lista)}")

        # Guardar lista completa
        with open(os.path.join(OUTPUT_DIR, "_partidos_lista.json"), "w", encoding="utf-8") as f:
            json.dump(partidos_lista, f, ensure_ascii=False, indent=2)

        # ── Paso 2: Procesar cada partido ──
        print("\n=== PASO 2: Procesando partidos ===")
        total = len(partidos_lista)

        for i, partido_info in enumerate(partidos_lista, 1):
            event_id = partido_info["event_id"]

            # Saltar si ya fue procesado
            if event_id in procesados:
                print(f"  [{i}/{total}] {event_id} ya procesado — saltando")
                continue

            # Saltar partidos que aún no se jugaron
            if partido_info.get("status") not in ("Ended", "FT", "AET", "AP"):
                print(f"  [{i}/{total}] {event_id} - {partido_info.get('status')} — no jugado aún")
                continue

            print(f"\n[{i}/{total}]", end="")
            try:
                partido = procesar_partido(page, partido_info)

                # Guardar JSON individual por partido
                filename = f"{event_id}_{partido_info['home_team']}_vs_{partido_info['away_team']}.json"
                filename = filename.replace(" ", "_").replace("/", "-")
                filepath = os.path.join(OUTPUT_DIR, filename)

                with open(filepath, "w", encoding="utf-8") as f:
                    json.dump(partido, f, ensure_ascii=False, indent=2)

                indice.append({**partido_info, "ok": True, "file": filename})

            except Exception as e:
                print(f"  ERROR procesando {event_id}: {e}")
                indice.append({**partido_info, "ok": False, "error": str(e)})

            # Guardar índice después de cada partido (checkpoint)
            with open(indice_path, "w", encoding="utf-8") as f:
                json.dump(indice, f, ensure_ascii=False, indent=2)

            time.sleep(DELAY_ENTRE_REQUESTS)

        browser.close()

    # Resumen final
    ok    = sum(1 for p in indice if p.get("ok"))
    error = sum(1 for p in indice if not p.get("ok"))
    print(f"\n=== COMPLETADO ===")
    print(f"Procesados OK:  {ok}")
    print(f"Con errores:    {error}")
    print(f"Archivos en:    {OUTPUT_DIR}/")


if __name__ == "__main__":
    main()

