/* Lecture par l'IA de la photo d'un bon d'achat de carburant (station STAR) : les champs sont proposés puis corrigés par la personne qui saisit */
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Content-Type": "application/json" };
const J = (o: unknown) => new Response(JSON.stringify(o), { status: 200, headers: CORS });
const SYS = `Tu lis la photo d'un bon d'achat de carburant (station-service en Mauritanie, montants en MRU / ouguiyas). Le bon peut être manuscrit ou imprimé.
Réponds UNIQUEMENT en json : {"date":"AAAA-MM-JJ ou vide","numero_bon":"n° du bon ou vide","vehicule":"immatriculation ou désignation du véhicule ou vide","carburant":"gasoil|essence|autre|vide","litres":nombre ou null,"prix_litre":nombre ou null,"montant":nombre ou null,"chauffeur":"nom ou vide","station":"nom de la station ou vide","doute":"ce qui est illisible ou incertain, en français, ou vide"}
N'invente rien : laisse vide ou null ce qui n'est pas lisible. Si le litrage et le prix au litre sont lisibles mais pas le montant, calcule le montant.`;
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { image, mime, vehicules } = await req.json();
    if (!image) return J({ erreur: "image_absente" });
    const mt = String(mime || "image/jpeg"), aide = Array.isArray(vehicules) && vehicules.length ? `\nVéhicules connus (code · désignation · immatriculation) : ${vehicules.slice(0, 40).join(" ; ")}. Si le bon correspond à l'un d'eux, renvoie son code dans "vehicule".` : "";
    const akey = Deno.env.get("ANTHROPIC_API_KEY"), okey = Deno.env.get("OPENAI_API_KEY"), pref = (Deno.env.get("IA_FOURNISSEUR") || "").toLowerCase();
    let txt = "";
    if (okey && (pref === "openai" || !akey)) {
      const r = await fetch("https://api.openai.com/v1/chat/completions", { method: "POST", headers: { authorization: "Bearer " + okey, "content-type": "application/json" }, body: JSON.stringify({ model: Deno.env.get("IA_MODEL_OPENAI") || "gpt-4o", temperature: 0, max_tokens: 500, response_format: { type: "json_object" }, messages: [{ role: "system", content: SYS + aide }, { role: "user", content: [{ type: "text", text: "Lis ce bon d'achat (json attendu)." }, { type: "image_url", image_url: { url: `data:${mt};base64,${image}` } }] }] }) });
      if (!r.ok) return J({ erreur: "ia_indisponible", detail: (await r.text()).slice(0, 200) }); txt = (await r.json()).choices?.[0]?.message?.content || "";
    } else if (akey) {
      const r = await fetch("https://api.anthropic.com/v1/messages", { method: "POST", headers: { "x-api-key": akey, "anthropic-version": "2023-06-01", "content-type": "application/json" }, body: JSON.stringify({ model: Deno.env.get("IA_MODEL") || "claude-sonnet-4-5", max_tokens: 500, system: SYS + aide, messages: [{ role: "user", content: [{ type: "image", source: { type: "base64", media_type: mt, data: image } }, { type: "text", text: "Lis ce bon d'achat (json attendu)." }] }] }) });
      if (!r.ok) return J({ erreur: "ia_indisponible", detail: (await r.text()).slice(0, 200) }); txt = ((await r.json()).content || []).map((c: { text?: string }) => c.text || "").join("");
    } else return J({ erreur: "ia_non_configuree" });
    const m = txt.match(/\{[\s\S]*\}/); return J({ champs: JSON.parse(m ? m[0] : txt) });
  } catch (e) { return J({ erreur: "echec", detail: String(e).slice(0, 200) }); }
});
