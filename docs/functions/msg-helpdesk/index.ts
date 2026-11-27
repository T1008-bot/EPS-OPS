/* Message WhatsApp au Help Desk : constat direct + demande adaptée (nettoyage → « Merci de nous lancer une complainte pour … », sinon « Merci d'intervenir ») */
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Content-Type": "application/json" };
const J = (o: unknown) => new Response(JSON.stringify(o), { status: 200, headers: CORS });
const LG: Record<string, string> = { fr: "français", en: "anglais", ar: "arabe" };
const SYS = (lg: string) => `Tu rédiges un message WhatsApp court adressé au Help Desk de l'aéroport de Nouakchott-Oumtounsy (le bureau qui enregistre les complaintes et les demandes d'intervention). L'expéditeur est EPS (prestataire de nettoyage et de manutention bagages).
Format exact, sans rien d'autre :
📍 <lieu précis>
<constat direct et factuel de ce qui existe, 1 à 3 phrases, sans formule>
<demande>
Règles pour la demande :
- Si l'intervention relève du nettoyage (propreté, déchets, ramassage, évacuation, grand ménage, désinfection, toilettes sales, flaque, odeur, vitres…), c'est EPS qui intervient, mais sur la base d'une complainte lancée par le Help Desk : écris « Merci de nous lancer une complainte pour <action précise adaptée : ramasser et évacuer les déchets et nettoyer l'emplacement / effectuer le grand ménage / nettoyer et désinfecter les toilettes / …>. »
- Sinon (technique, maintenance, plomberie, électricité, climatisation, porte…) : « Merci d'intervenir » suivi au besoin d'une précision courte.
- Aucune signature, aucun nom d'équipe, aucune référence interne, aucune formule de politesse finale.
- Si une urgence est indiquée, ajoute en première ligne « ⚠️ <urgence> ».
- Langue du message : ${lg}. N'invente aucun fait.
Réponds UNIQUEMENT en json : {"nettoyage": true|false, "message": "..."}`;
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { lieu, constat, urgence, categorie, intervention, langue } = await req.json();
    if (!String(constat || "").trim()) return J({ erreur: "vide" });
    const user = `Lieu : ${String(lieu || "à préciser").slice(0, 300)}\nConstat : ${String(constat).slice(0, 3000)}\nCatégorie choisie : ${String(categorie || "").slice(0, 80)}\nIntervention souhaitée : ${String(intervention || "").slice(0, 500)}\nUrgence : ${String(urgence || "").slice(0, 200)}\n(json attendu)`;
    const sys = SYS(LG[String(langue || "fr")] || "français");
    const akey = Deno.env.get("ANTHROPIC_API_KEY"), okey = Deno.env.get("OPENAI_API_KEY"), pref = (Deno.env.get("IA_FOURNISSEUR") || "").toLowerCase();
    let txt = "";
    if (okey && (pref === "openai" || !akey)) {
      const r = await fetch("https://api.openai.com/v1/chat/completions", { method: "POST", headers: { authorization: "Bearer " + okey, "content-type": "application/json" }, body: JSON.stringify({ model: Deno.env.get("IA_MODEL_OPENAI") || "gpt-4o", temperature: 0.2, max_tokens: 700, response_format: { type: "json_object" }, messages: [{ role: "system", content: sys }, { role: "user", content: user }] }) });
      if (!r.ok) return J({ erreur: "ia_indisponible" }); txt = (await r.json()).choices?.[0]?.message?.content || "";
    } else if (akey) {
      const r = await fetch("https://api.anthropic.com/v1/messages", { method: "POST", headers: { "x-api-key": akey, "anthropic-version": "2023-06-01", "content-type": "application/json" }, body: JSON.stringify({ model: Deno.env.get("IA_MODEL") || "claude-sonnet-4-5", max_tokens: 700, system: sys, messages: [{ role: "user", content: user }] }) });
      if (!r.ok) return J({ erreur: "ia_indisponible" }); txt = ((await r.json()).content || []).map((c: { text?: string }) => c.text || "").join("");
    } else return J({ erreur: "ia_non_configuree" });
    const m = txt.match(/\{[\s\S]*\}/); const o = JSON.parse(m ? m[0] : txt);
    return J({ nettoyage: !!o.nettoyage, message: String(o.message || "").trim() });
  } catch (e) { return J({ erreur: "echec", detail: String(e).slice(0, 200) }); }
});
