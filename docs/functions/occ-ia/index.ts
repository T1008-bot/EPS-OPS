/* Conception d'un thème d'occasion par l'IA (texte français et arabe, couleurs, icône, animation) à partir d'une description libre */
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Content-Type": "application/json" };
const J = (o: unknown) => new Response(JSON.stringify(o), { status: 200, headers: CORS });
const SYS = `Tu conçois le bandeau d'une occasion (fête, journée, anniversaire) pour l'application EPS OPS d'EPS (nettoyage et manutention bagages, aéroport de Nouakchott, Mauritanie). Le bandeau s'affiche en haut de l'accueil, sur une seule ligne (ou défilant).
On te donne une demande libre et, éventuellement, l'occasion actuelle à modifier (json). Garde ce qui n'est pas demandé de changer.
Réponds UNIQUEMENT en json :
{"titre": "nom court de l'occasion", "txt": "texte du bandeau en français, chaleureux, court (max 70 caractères), adressé aux équipes", "txt_ar": "même message en arabe", "sous": "texte court entre étoiles ou vide (ex. date, '{ANS}e anniversaire')", "palette": "une de : mauritanie, nuit_or, vert_aid, vert_or, bleu, bleu_ciel, eau, orange, violet", "ic": "une de : drapeau, 🎉, 🎆, 🌙, 🐑, 🕌, 👷, 🌍, 🧼, 🧴, 🦺, ✈️, ♀️, ⭐, 🏆, 🎂", "defile": true|false, "conf": true|false, "langue": "fr|ar|fr_ar", "explication": "une phrase en français sur les choix"}
{ANS} = nombre d'années depuis l'année de référence, {Y} = année en cours : tu peux les utiliser dans les textes. Confettis seulement pour les grandes fêtes et anniversaires. Pas d'emoji dans les textes.`;
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { demande, actuelle } = await req.json();
    if (!String(demande || "").trim()) return J({ erreur: "vide" });
    const user = `Demande : ${String(demande).slice(0, 1500)}\n\nOccasion actuelle (json) : ${JSON.stringify(actuelle || {}).slice(0, 3000)}\n\n(json attendu)`;
    const akey = Deno.env.get("ANTHROPIC_API_KEY"), okey = Deno.env.get("OPENAI_API_KEY"), pref = (Deno.env.get("IA_FOURNISSEUR") || "").toLowerCase();
    let txt = "";
    if (okey && (pref === "openai" || !akey)) {
      const r = await fetch("https://api.openai.com/v1/chat/completions", { method: "POST", headers: { authorization: "Bearer " + okey, "content-type": "application/json" }, body: JSON.stringify({ model: Deno.env.get("IA_MODEL_OPENAI") || "gpt-4o", temperature: 0.4, max_tokens: 600, response_format: { type: "json_object" }, messages: [{ role: "system", content: SYS }, { role: "user", content: user }] }) });
      if (!r.ok) return J({ erreur: "ia_indisponible" }); txt = (await r.json()).choices?.[0]?.message?.content || "";
    } else if (akey) {
      const r = await fetch("https://api.anthropic.com/v1/messages", { method: "POST", headers: { "x-api-key": akey, "anthropic-version": "2023-06-01", "content-type": "application/json" }, body: JSON.stringify({ model: Deno.env.get("IA_MODEL") || "claude-sonnet-4-5", max_tokens: 600, system: SYS, messages: [{ role: "user", content: user }] }) });
      if (!r.ok) return J({ erreur: "ia_indisponible" }); txt = ((await r.json()).content || []).map((c: { text?: string }) => c.text || "").join("");
    } else return J({ erreur: "ia_non_configuree" });
    const m = txt.match(/\{[\s\S]*\}/); return J({ champs: JSON.parse(m ? m[0] : txt) });
  } catch (e) { return J({ erreur: "echec", detail: String(e).slice(0, 200) }); }
});
