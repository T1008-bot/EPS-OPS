/* Complaintes Help Desk (BDM) reçues par e-mail (relais Gmail) : analyse IA, enregistrement, tâche pour l'équipe nettoyage en service */
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-eps-secret", "Content-Type": "application/json" };
const J = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: CORS });
const SYS = `Tu lis un e-mail reçu par EPS (nettoyage professionnel et manutention bagages à l'aéroport de Nouakchott-Oumtounsy). Il peut s'agir d'une complainte (réclamation) enregistrée au Help Desk de l'aéroport avec un numéro de complainte « BDM ».
Réponds UNIQUEMENT au format json : {"est_complainte":true|false,"bdm":"numéro de complainte BDM tel qu'écrit ou chaîne vide","objet":"objet court en français (max 90 caractères)","lieu":"lieu précis (zone, porte, niveau, toilettes…) ou chaîne vide","domaine":"nettoyage|manutention|technique|autre","concerne_eps":true|false,"priorite":"normale|haute|urgente"}
concerne_eps = true si la complainte demande une action d'EPS : nettoyage, propreté, toilettes sales, odeurs, déchets, poubelles, déversement, flaque, vitres, hygiène, désinfection (ou manutention bagages). Une panne technique (électricité, plomberie, climatisation) adressée à la maintenance ne concerne pas EPS, sauf si elle demande aussi un nettoyage. N'invente aucun numéro.`;
async function ia(t: string) {
  const akey = Deno.env.get("ANTHROPIC_API_KEY"), okey = Deno.env.get("OPENAI_API_KEY"), pref = (Deno.env.get("IA_FOURNISSEUR") || "").toLowerCase(); let out = "";
  if (okey && (pref === "openai" || !akey)) { const r = await fetch("https://api.openai.com/v1/chat/completions", { method: "POST", headers: { authorization: "Bearer " + okey, "content-type": "application/json" }, body: JSON.stringify({ model: Deno.env.get("IA_MODEL_OPENAI") || "gpt-4o", temperature: 0, max_tokens: 600, response_format: { type: "json_object" }, messages: [{ role: "system", content: SYS }, { role: "user", content: "E-mail (json attendu en réponse) :\n" + t }] }) }); if (r.ok) out = (await r.json()).choices?.[0]?.message?.content || ""; }
  else if (akey) { const r = await fetch("https://api.anthropic.com/v1/messages", { method: "POST", headers: { "x-api-key": akey, "anthropic-version": "2023-06-01", "content-type": "application/json" }, body: JSON.stringify({ model: Deno.env.get("IA_MODEL") || "claude-sonnet-4-5", max_tokens: 600, system: SYS, messages: [{ role: "user", content: t }] }) }); if (r.ok) out = ((await r.json()).content || []).map((c: { text?: string }) => c.text || "").join(""); }
  try { const m = out.match(/\{[\s\S]*\}/); return JSON.parse(m ? m[0] : out); } catch { return null; }
}
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  try {
    const b = await req.json(), sec = req.headers.get("x-eps-secret") || b.secret || "";
    const { data: s } = await sb.from("app_secrets").select("v").eq("k", "msg_secret").maybeSingle();
    if (!(sec && s && sec === s.v)) return J({ erreur: "non_autorise" }, 401);
    const sujet = String(b.subject || "").slice(0, 300), corps = String(b.body || "").replace(/<style[\s\S]*?<\/style>/gi, " ").replace(/<[^>]+>/g, " ").replace(/&nbsp;/g, " ").replace(/\s+/g, " ").trim().slice(0, 6000);
    const recu = b.received_at ? new Date(b.received_at) : new Date(), mid = String(b.message_id || "") || null;
    if (mid) { const { data: d } = await sb.from("bdm_recus").select("id").eq("message_id", mid).maybeSingle(); if (d) return J({ doublon: true }); }
    const a = await ia(`Objet : ${sujet}\nDe : ${b.from || ""}\n\n${corps}`) || {};
    if (a && a.est_complainte === false) return J({ ignore: true, raison: "pas une complainte" });
    const bdm = String(a.bdm || (sujet + " " + corps).match(/\bBDM\s*[:#n°ºo.\- ]*\s*([A-Z0-9\-\/]{3,20})/i)?.[1] || "").trim().replace(/^BDM\s*[:#n°º.\- ]*/i, "") || null;
    const { data: row, error } = await sb.from("bdm_recus").insert({ message_id: mid, recu_le: recu.toISOString(), expediteur: String(b.from || "").slice(0, 200) || null, sujet, texte: corps, bdm, objet: String(a.objet || "").slice(0, 200) || null, lieu: String(a.lieu || "") || null, domaine: String(a.domaine || "") || null, concerne_eps: !!a.concerne_eps, priorite: String(a.priorite || "") || null }).select("id").single();
    if (error) return J({ erreur: error.message }, 500);
    /* toujours : la complainte apparaît dans Signalements › Help Desk ; la tâche n’est créée que si EPS est concernée */
    const r = await sb.rpc("bdm_recu_tache", { p_id: row.id }), tache = r.data;
    return J({ ok: true, id: row.id, bdm, concerne_eps: !!a.concerne_eps, tache });
  } catch (e) { return J({ erreur: "echec", detail: String(e).slice(0, 200) }, 500); }
});
