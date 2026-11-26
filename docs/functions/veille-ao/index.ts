/* Veille quotidienne des appels d'offres (beta.mr, TendersInfo, GlobalTenders) : nettoyage professionnel et lutte anti-parasitaire (Mauritanie) */
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-va-token", "Content-Type": "application/json" };
const J = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: CORS });
const TOKEN = Deno.env.get("VEILLE_TOKEN") || "<jeton défini sur Supabase>";  // jeton non versionné
const UA = { "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36", "Accept-Language": "fr,en;q=0.8" };
/* mots-clés : français et anglais */
const MOTS = /nettoy|proprete|entretien-des-locaux|entretien-et-nettoyage|(?:^|-)menage|hygien|assainiss|desinfect|desinsect|deratis|fumig|parasit|nuisible|termite|cafard|rongeur|moustique|traitement-phyto|dechet|ordure|lavage|vitre|blanchiss|facility|multiservice|clean|janitor|housekeep|pest|rodent|insect|disinfect|sanitation|waste|garbage|vector-control|sanitary|washing/;
/* avis de recrutement de personnes : exclus, sauf s'il s'agit d'un prestataire / d'une entreprise */
const EMPLOI = /^(un|une|des|deux|trois|quatre|cinq|plusieurs|\d+)-|(^|-)(recrutement|recrute|avis-de-recrutement|offre-d-?emploi|poste|stage|stagiaire|consultant|consultante|expert|experte|agent|agents|technicien|chauffeur|assistant|assistante|responsable|charge|chargee|coordinat|directeur|directrice|ingenieur|comptable|infirmier|infirmiere|specialiste|gestionnaire|superviseur|chef|manager|accountant|officer|driver|engineer|specialist|coordinator|director|internship|vacancy|job|seeking)(-|$)/;
const PRESTA = /prestataire|entreprise|societe|cabinet|bureau-d|fournisseur|fourniture|prestation|services?-de|marche|appel-d|avis-d-appel|consultation|dao|lot|firm|company|contractor|supply|provision|services|operateur/;
type Source = { nom: string; pages: [string, string][]; lien: RegExp };
const SOURCES: Source[] = [
  { nom: "beta.mr", lien: /https:\/\/beta\.mr\/beta\/offre\/([a-z0-9-]+)\/(\d+)/g,
    pages: [["https://beta.mr/beta/liste_offres/3", "Appels d'offres internationaux"], ["https://beta.mr/beta/liste_offres/4", "Appels d'offres locaux"], ["https://beta.mr/beta/liste_offres/5", "Consultations"], ["https://beta.mr/beta/liste_offres/6", "Manifestations d'intérêt"], ["https://beta.mr/beta/liste_offres/7", "Avis & infos"], ["https://beta.mr/beta/liste_offres/10", "Appels d'offres"], ["https://beta.mr/", "Annonces (accueil)"]] },
  { nom: "tendersinfo", lien: /https:\/\/www\.tendersinfo\.com\/tenders_details\/([a-z0-9-]+?)-(\d{6,})/g,
    pages: [["https://www.tendersinfo.com/global-mauritania-tenders.php", "Mauritanie — tous les appels d'offres"], ["https://www.tendersinfo.com/global-mauritania-tenders/services-tenders.php", "Mauritanie — services"], ["https://www.tendersinfo.com/global-mauritania-tenders/water-and-sanitation-tenders.php", "Mauritanie — eau et assainissement"]] },
  { nom: "globaltenders", lien: /https:\/\/www\.globaltenders\.com\/tender-detail\/([^"'\s<>]+?)-([A-Za-z0-9]{16})(?=["'\s<>])/g,
    pages: [["https://www.globaltenders.com/mauritania-tenders", "Mauritanie — appels d'offres"]] },
];
const SB = Deno.env.get("SUPABASE_URL")!, SK = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = (path: string, init: RequestInit = {}) => fetch(SB + "/rest/v1/" + path, { ...init, headers: { apikey: SK, authorization: "Bearer " + SK, "content-type": "application/json", Prefer: "return=representation", ...(init.headers || {}) } });
const txt = (h: string) => h.replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/gi, " ").replace(/<[^>]+>/g, " ").replace(/&nbsp;/g, " ").replace(/&rsquo;|&#039;/g, "’").replace(/&eacute;/g, "é").replace(/&egrave;/g, "è").replace(/&agrave;/g, "à").replace(/&ccedil;/g, "ç").replace(/&ecirc;/g, "ê").replace(/&amp;/g, "&").replace(/\s+/g, " ").trim();
const dec = (x: string) => { try { return decodeURIComponent(x); } catch { return x; } };
const norm = (x: string) => dec(x).toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/(acute|grave|circ|cedil|uml|rsquo|lsquo|nbsp|amp|laquo|raquo)/g, "");
const MOIS: Record<string, number> = { janvier: 1, fevrier: 2, février: 2, mars: 3, avril: 4, mai: 5, juin: 6, juillet: 7, aout: 8, août: 8, septembre: 9, octobre: 10, novembre: 11, decembre: 12, décembre: 12, jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12 };
function dateFr(s: string): string | null { const m = s.toLowerCase().match(/(\d{1,2})\s+([a-zéû]+)\.?\s+(\d{4})/); if (!m) return null; const mo = MOIS[m[2]] || MOIS[m[2].slice(0, 3)]; if (!mo) return null; return `${m[3]}-${String(mo).padStart(2, "0")}-${m[1].padStart(2, "0")}`; }
let IAERR = "";
async function ia(items: { titre: string; organisme: string; texte: string }[]) {
  const sys = `Tu fais la veille commerciale d'EPS, entreprise de nettoyage professionnel, manutention bagages et désinfection / lutte anti-parasitaire à Nouakchott (Mauritanie). Pour chaque annonce (appel d'offres, consultation, manifestation d'intérêt ; en français ou en anglais), dis si elle est PERTINENTE pour EPS : prestations de nettoyage professionnel (locaux, bureaux, hôpitaux, aéroport, vitres, hygiène, entretien) ou de lutte anti-parasitaire (dératisation, désinsectisation, désinfection, fumigation, traitement contre termites, cafards, moustiques…), à Nouakchott ou sans lieu précis en Mauritanie. SEULES les demandes de PRESTATION (appel d'offres, consultation, demande de cotation, manifestation d'intérêt adressée à des entreprises / prestataires) sont pertinentes. Tout avis de recrutement de personnel (offre d'emploi, stage, recrutement d'un agent d'entretien, d'un technicien ou d'un consultant individuel) est NON pertinent, même s'il parle de nettoyage ou d'hygiène. Un simple achat de produits ou d'équipements sans prestation est aussi non pertinent.
Réponds UNIQUEMENT au format json suivant : {"items":[{"type":"prestation|recrutement|achat|autre","pertinent":true|false,"domaine":"nettoyage|anti-parasitaire|nettoyage et anti-parasitaire|autre","lieu":"ville / lieu des prestations ou chaîne vide","nouakchott":true|false,"organisme":"acheteur si connu ou chaîne vide","date_limite":"AAAA-MM-JJ ou chaîne vide","titre_fr":"titre court en français","resume":"2 à 3 phrases en français : objet, lieu, date limite et conditions clés (visite, caution, dépôt)"}]} dans le même ordre que les annonces reçues.`;
  const user = "Annonces (json) :\n" + JSON.stringify(items.map(x => ({ titre: x.titre, organisme: x.organisme, texte: x.texte.slice(0, 3500) })));
  const akey = Deno.env.get("ANTHROPIC_API_KEY"), okey = Deno.env.get("OPENAI_API_KEY"), pref = (Deno.env.get("IA_FOURNISSEUR") || "").toLowerCase();
  let out = "", err = "";
  if (okey && (pref === "openai" || !akey)) { const r = await fetch("https://api.openai.com/v1/chat/completions", { method: "POST", headers: { authorization: "Bearer " + okey, "content-type": "application/json" }, body: JSON.stringify({ model: Deno.env.get("IA_MODEL_OPENAI") || "gpt-4o", temperature: 0, max_tokens: 4000, response_format: { type: "json_object" }, messages: [{ role: "system", content: sys }, { role: "user", content: user }] }) }); if (r.ok) out = (await r.json()).choices?.[0]?.message?.content || ""; else err = "openai " + r.status + " " + (await r.text()).slice(0, 200); }
  else if (akey) { const r = await fetch("https://api.anthropic.com/v1/messages", { method: "POST", headers: { "x-api-key": akey, "anthropic-version": "2023-06-01", "content-type": "application/json" }, body: JSON.stringify({ model: Deno.env.get("IA_MODEL") || "claude-sonnet-4-5", max_tokens: 4000, system: sys, messages: [{ role: "user", content: user }] }) }); if (r.ok) out = ((await r.json()).content || []).map((c: { text?: string }) => c.text || "").join(""); else err = "anthropic " + r.status + " " + (await r.text()).slice(0, 200); }
  IAERR = err || (out ? "" : "réponse vide");
  try { const m = out.match(/\{[\s\S]*\}/); return (JSON.parse(m ? m[0] : out).items || []) as Record<string, unknown>[]; } catch { IAERR = IAERR || "json illisible : " + out.slice(0, 200); return []; }
}
async function get(u: string) { try { const c = new AbortController(), t = setTimeout(() => c.abort(), 25000); const r = await fetch(u, { headers: UA, signal: c.signal }); clearTimeout(t); return r.ok ? await r.text() : ""; } catch { return ""; } }
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.headers.get("x-va-token") !== TOKEN) return J({ erreur: "non_autorise" }, 401);
  const { recap = true } = await req.json().catch(() => ({}));
  const bilan: Record<string, unknown> = {};
  try {
    const rows: Record<string, unknown>[] = [];
    for (const S of SOURCES) {
      /* 1. annonces listées */
      const vus = new Map<string, { url: string; slug: string; cat: string }>();
      for (const [u, cat] of S.pages) { const h = await get(u); for (const m of h.matchAll(S.lien)) if (!vus.has(m[2])) vus.set(m[2], { url: m[0], slug: m[1], cat }); }
      /* 2. déjà connues */
      const ids = [...vus.keys()], dej = new Set<string>();
      if (ids.length) { const r = await db(`veille_ao?select=source_id&source=eq.${S.nom}&source_id=in.(${ids.map(encodeURIComponent).join(",")})`); (await r.json() as { source_id: string }[]).forEach(x => dej.add(x.source_id)); }
      const cand = ids.filter(i => { const sl = norm(vus.get(i)!.slug); return !dej.has(i) && MOTS.test(sl) && (!EMPLOI.test(sl) || PRESTA.test(sl)); });
      /* 3. détail */
      const det: { id: string; url: string; cat: string; titre: string; organisme: string; dl: string | null; dlt: string; texte: string }[] = [];
      for (const id of cand.slice(0, 20)) { const v = vus.get(id)!, raw = await get(v.url); const t = txt(raw), ogt = raw.match(/property="og:title" content="([^"]*)"/), h1 = raw.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i), tit = ogt ? txt(ogt[1].replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&")) : h1 ? txt(h1[1]) : "";
        const dm = t.match(/(?:Date limite|Deadline|Closing date|Date de clôture)\s*:?\s*(\d{1,2}\s+[a-zA-Zéûè]+\.?\s+\d{4})/i), i0 = Math.max(0, t.indexOf(dm ? dm[0] : "Description")), og = t.match(/-->\s*([^-]{3,80}?)\s*-->\s*\1/);
        det.push({ id, url: v.url, cat: v.cat, titre: (tit || norm(v.slug).replace(/-/g, " ")).slice(0, 400), organisme: og ? og[1].trim() : "", dl: dm ? dateFr(dm[1]) : null, dlt: dm ? dm[1].trim() : "", texte: t ? t.slice(Math.max(0, i0 - 600), i0 + 4000) : norm(v.slug).replace(/-/g, " ") }); }
      /* 4. analyse IA */
      const A = det.length ? await ia(det) : [];
      det.forEach((d, i) => { const a = A[i] || {}, dlIA = /^\d{4}-\d\d-\d\d$/.test(String(a.date_limite || "")) ? String(a.date_limite) : null;
        rows.push({ source: S.nom, source_id: d.id, url: d.url, titre: (S.nom != "beta.mr" && a.titre_fr ? String(a.titre_fr) : d.titre).slice(0, 400), organisme: d.organisme || String(a.organisme || "") || null, categorie: d.cat, date_limite: d.dl || dlIA, date_limite_txt: d.dlt || (dlIA ? dlIA.split("-").reverse().join("/") : null), domaine: String(a.domaine || "") || null, nouakchott: a.nouakchott == null ? null : !!a.nouakchott, pertinent: A.length ? !!a.pertinent && String(a.type || "prestation") == "prestation" : true, resume: String(a.resume || "") || null }); });
      bilan[S.nom] = { annonces: ids.length, candidates: cand.length, analysees: det.length, ia_erreur: det.length ? IAERR || undefined : undefined };
    }
    if (rows.length) await db("veille_ao?on_conflict=source,source_id", { method: "POST", headers: { Prefer: "resolution=ignore-duplicates" }, body: JSON.stringify(rows) });
    /* 5. récapitulatif quotidien */
    const nouv = rows.filter(r => r.pertinent) as { titre: string; organisme: string | null; date_limite_txt: string | null; source: string }[];
    if (recap) {
      const today = new Date().toISOString().slice(0, 10), r = await db(`veille_ao?select=id&pertinent=eq.true&date_limite=gte.${today}`), ouverts = (await r.json() as unknown[]).length;
      const corps = nouv.length ? nouv.slice(0, 6).map(x => `• ${x.titre.slice(0, 90)}${x.organisme ? " (" + x.organisme + ")" : ""}${x.date_limite_txt ? " — limite " + x.date_limite_txt : ""} [${x.source}]`).join("\n") + (nouv.length > 6 ? `\n… +${nouv.length - 6}` : "") : "Aucun nouvel appel d’offres pertinent aujourd’hui.";
      await db("rpc/notifier", { method: "POST", body: JSON.stringify({ p_roles: ["direction", "responsable_ops", "coordinateur_ops"], p_users: null, p_cat: "veille", p_titre: `📢 Veille appels d’offres : ${nouv.length} nouveau(x) · ${ouverts} ouvert(s)`, p_corps: corps, p_lien: "veille", p_ref: "veille:" + today, p_sauf: null }) });
    }
    return J({ ...bilan, pertinentes: nouv.length });
  } catch (e) { return J({ erreur: "echec", detail: String(e).slice(0, 300), ...bilan }); }
});
