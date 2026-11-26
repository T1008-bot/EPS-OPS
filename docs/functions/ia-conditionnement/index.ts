const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Content-Type": "application/json" };
const J = (o: unknown) => new Response(JSON.stringify(o), { status: 200, headers: CORS });
const SYS = `Tu lis le conditionnement (emballage) d'articles de magasin d'EPS (nettoyage, manutention bagages, EPI) pour calculer des totaux et des consommations.
On te donne un tableau JSON de lignes : {article, unite_catalogue, quantite, unite, observation}.
Pour CHAQUE ligne, dans le même ordre, réponds par un objet :
{"emballage": unité dans laquelle la quantité est exprimée (ex. "carton", "colis", "bidon", "barrique"), "facteur": nombre d'unités de base contenues dans UN emballage (nombre, ex. 12 pour "12/carton", 48 pour "4x12/colis", 50 pour "50 kg/barrique"), "unite_base": unité de base (ex. "rouleau", "kg", "L", "paire", "pièce"), "total_base": quantite × facteur si la quantité est exprimée dans l'emballage, sinon quantite (déjà en unité de base), "interpretation": phrase courte en français (ex. "10 cartons × 12 rouleaux = 120 rouleaux")}
Règles : si l'observation ne parle pas de conditionnement ou est vide, facteur = 1, emballage = unite, unite_base = unite (ou unite_catalogue) et total_base = quantite. Si la quantité est déjà exprimée dans l'unité de base (ex. unite "rouleau" et observation "carton de 12"), total_base = quantite et facteur = 12 (information de conditionnement seulement). N'invente aucun nombre absent. Nombres décimaux avec un point.
Réponds UNIQUEMENT par {"lignes":[...]} en JSON valide.`;
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { lignes } = await req.json(); if (!Array.isArray(lignes) || !lignes.length) return J({ erreur: "vide" });
    const user = JSON.stringify(lignes.slice(0, 60).map((l: Record<string, unknown>) => ({ article: String(l.article || ""), unite_catalogue: String(l.unite_catalogue || ""), quantite: Number(l.quantite) || 0, unite: String(l.unite || ""), observation: String(l.observation || "").slice(0, 200) })));
    const akey = Deno.env.get("ANTHROPIC_API_KEY"), okey = Deno.env.get("OPENAI_API_KEY"), pref = (Deno.env.get("IA_FOURNISSEUR") || "").toLowerCase();
    let txt = "";
    if (okey && (pref === "openai" || !akey)) {
      const r = await fetch("https://api.openai.com/v1/chat/completions", { method: "POST", headers: { authorization: "Bearer " + okey, "content-type": "application/json" }, body: JSON.stringify({ model: Deno.env.get("IA_MODEL_OPENAI") || "gpt-4o", temperature: 0, max_tokens: 2500, response_format: { type: "json_object" }, messages: [{ role: "system", content: SYS }, { role: "user", content: user }] }) });
      if (!r.ok) return J({ erreur: "ia_indisponible" }); txt = (await r.json()).choices?.[0]?.message?.content || "";
    } else if (akey) {
      const r = await fetch("https://api.anthropic.com/v1/messages", { method: "POST", headers: { "x-api-key": akey, "anthropic-version": "2023-06-01", "content-type": "application/json" }, body: JSON.stringify({ model: Deno.env.get("IA_MODEL") || "claude-sonnet-4-5", max_tokens: 2500, system: SYS, messages: [{ role: "user", content: user }] }) });
      if (!r.ok) return J({ erreur: "ia_indisponible" }); txt = ((await r.json()).content || []).map((c: { text?: string }) => c.text || "").join("");
    } else return J({ erreur: "ia_non_configuree" });
    const m = txt.match(/\{[\s\S]*\}/); const o = JSON.parse(m ? m[0] : txt);
    return J({ lignes: Array.isArray(o.lignes) ? o.lignes : [] });
  } catch (e) { return J({ erreur: "echec", detail: String(e).slice(0, 200) }); }
});
