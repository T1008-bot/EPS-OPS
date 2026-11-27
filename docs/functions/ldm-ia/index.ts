/* Interprétation par l'IA des messages de chargement (LDM / CPM) : message clair en français, prêt à partager aux équipes de Manutention bagages */
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Content-Type": "application/json" };
const J = (o: unknown) => new Response(JSON.stringify(o), { status: 200, headers: CORS });
const SYS = `Tu es agent de coordination de la Manutention bagages d'EPS à l'aéroport de Nouakchott-Oumtounsy (NKC). On te donne les messages IATA bruts d'un vol : LDM (Load Message) et/ou CPM (Container/Pallet Distribution Message).
Rédige un message WhatsApp court en français pour l'équipe de Manutention bagages, uniquement à partir des données présentes (n'invente rien, ne devine pas un code inconnu : recopie-le tel quel entre parenthèses).
Format, une information par ligne, en omettant toute ligne sans donnée :
📦 LDM/CPM — Vol <numéro> du <date> (<arrivée/départ>, <provenance/destination>)
✈️ Avion : <immatriculation> · version <config> · équipage <x/y>
👥 Passagers : <total> (adultes / enfants / bébés ; par classe si indiqué) · transit éventuel
🧳 Bagages : <pièces> pcs / <poids> kg (par destination si plusieurs)
📮 Fret : <kg> · Poste : <kg>
🗂 Répartition par soute : soute 1 : … kg · soute 2 : … (et positions/ULD si CPM)
⚠️ Chargements spéciaux : DGR, AVI, HUM, PER, WCH… avec leur position (si présents)
Total sous-plancher : <kg> (si calculable à partir des données)
Si le CPM donne des ULD : liste « position : ULD · contenu (B bagages, C fret, M poste) · poids ».
Pas de signature, pas de formule de politesse. Réponds UNIQUEMENT en json : {"message": "..."}`;
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { vol, sens, date, route, ldm, cpm } = await req.json();
    if (!String(ldm || "").trim() && !String(cpm || "").trim()) return J({ erreur: "vide" });
    const user = `Vol : ${vol || "?"} · ${sens == "A" ? "arrivée" : "départ"} · ${date || ""} · ${route || ""}\n\nLDM :\n${String(ldm || "(aucun)").slice(0, 6000)}\n\nCPM :\n${String(cpm || "(aucun)").slice(0, 6000)}\n\n(json attendu)`;
    const akey = Deno.env.get("ANTHROPIC_API_KEY"), okey = Deno.env.get("OPENAI_API_KEY"), pref = (Deno.env.get("IA_FOURNISSEUR") || "").toLowerCase();
    let txt = "";
    if (okey && (pref === "openai" || !akey)) {
      const r = await fetch("https://api.openai.com/v1/chat/completions", { method: "POST", headers: { authorization: "Bearer " + okey, "content-type": "application/json" }, body: JSON.stringify({ model: Deno.env.get("IA_MODEL_OPENAI") || "gpt-4o", temperature: 0, max_tokens: 900, response_format: { type: "json_object" }, messages: [{ role: "system", content: SYS }, { role: "user", content: user }] }) });
      if (!r.ok) return J({ erreur: "ia_indisponible" }); txt = (await r.json()).choices?.[0]?.message?.content || "";
    } else if (akey) {
      const r = await fetch("https://api.anthropic.com/v1/messages", { method: "POST", headers: { "x-api-key": akey, "anthropic-version": "2023-06-01", "content-type": "application/json" }, body: JSON.stringify({ model: Deno.env.get("IA_MODEL") || "claude-sonnet-4-5", max_tokens: 900, system: SYS, messages: [{ role: "user", content: user }] }) });
      if (!r.ok) return J({ erreur: "ia_indisponible" }); txt = ((await r.json()).content || []).map((c: { text?: string }) => c.text || "").join("");
    } else return J({ erreur: "ia_non_configuree" });
    const m = txt.match(/\{[\s\S]*\}/); const o = JSON.parse(m ? m[0] : txt);
    return J({ message: String(o.message || "").trim() });
  } catch (e) { return J({ erreur: "echec", detail: String(e).slice(0, 200) }); }
});
