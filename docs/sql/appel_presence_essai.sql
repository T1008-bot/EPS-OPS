-- EPS OPS — Module « Appel dans l'app » (en essai, désactivable).
-- Appliqué le 18/11/2026. À exécuter une fois dans Supabase : Dashboard → SQL Editor → New query → coller ce fichier → Run.
-- Jotform reste la situation officielle : l'appel est enregistré à part (table appels) et ne modifie pas les statuts.
-- Désactiver : update config_alertes set valeur = '{"actif": false}' where cle = 'appel_app';

insert into public.config_alertes(cle, valeur, description) values ('appel_app', '{"actif": true}', 'Appel de l’équipe dans l’app (en essai). actif=false masque le module et coupe les relances ; la situation officielle reste Jotform.')
on conflict (cle) do nothing;

alter table public.statuts_jour add column if not exists retard boolean not null default false,
  add column if not exists retard_heure text, add column if not exists retard_a_confirmer boolean not null default false;

create table if not exists public.appels (
  id bigint generated always as identity primary key, jour date not null, equipe text not null, service text not null,
  fait_par uuid, fait_nom text, fait_le timestamptz not null default now(), lat double precision, lon double precision, precision_m double precision,
  effectif int, presents int, lignes jsonb not null default '[]', renforts jsonb not null default '[]', superviseurs text[], chefs text[],
  unique (jour, equipe));
alter table public.appels enable row level security;
create policy ap_r on public.appels for select using (mon_role() is not null);

create or replace function public.appel_actif() returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce((select (valeur->>'actif')::boolean from config_alertes where cle = 'appel_app'), false) $$;

create or replace function public.garde_du(d date) returns int language sql immutable as $$
  select (array[3,1,2])[(((d - date '2026-11-03') % 3) + 3) % 3 + 1] $$;

create or replace function public.appel_enregistrer(p_jour date, p_equipe text, p_lignes jsonb, p_renforts jsonb, p_lat double precision, p_lon double precision,
  p_prec double precision, p_sup text[], p_chefs text[]) returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare me profiles; eff int; nabs int; svc text; cib text;
begin
  if not appel_actif() then raise exception 'Le module d’appel est désactivé'; end if;
  select * into me from profiles where id = auth.uid() and actif;
  if not found or me.role not in ('direction','responsable_ops','coordinateur_ops','superviseur_principal','superviseur_nettoyage','superviseur_bagages','chef_nettoyage','chef_bagages') then
    raise exception 'Seuls les chefs d’équipe, superviseurs et responsables peuvent faire l’appel'; end if;
  svc := case when p_equipe like 'Manutention%' then 'manutention' else 'nettoyage' end;
  select count(*) into eff from agents where actif and equipe = p_equipe and coalesce(service,'') not like 'Encadrement%';
  select count(*) into nabs from jsonb_array_elements(coalesce(p_lignes,'[]')) l where l->>'s' in ('nj','j','c','mp');
  insert into appels(jour, equipe, service, fait_par, fait_nom, fait_le, lat, lon, precision_m, effectif, presents, lignes, renforts, superviseurs, chefs)
  values (p_jour, p_equipe, svc, me.id, me.nom, now(), p_lat, p_lon, p_prec, eff, eff - nabs, coalesce(p_lignes,'[]'), coalesce(p_renforts,'[]'), p_sup, p_chefs)
  on conflict (jour, equipe) do update set fait_par = excluded.fait_par, fait_nom = excluded.fait_nom, fait_le = now(), lat = excluded.lat, lon = excluded.lon,
    precision_m = excluded.precision_m, effectif = excluded.effectif, presents = excluded.presents, lignes = excluded.lignes, renforts = excluded.renforts,
    superviseurs = excluded.superviseurs, chefs = excluded.chefs;
  cib := case when p_equipe like 'Manutention%' then 'Manutention M' else 'Nettoyage N' end || right(p_equipe, 1);
  update taches set statut = 'fait', maj_nom = me.nom, maj_le = now(), commentaire = 'Appel fait dans l’app : ' || (eff - nabs) || '/' || eff || ' présents'
   where jour = p_jour and modele like '%appel%' and cible = cib and statut not in ('fait','annule');
  return jsonb_build_object('effectif', eff, 'presents', eff - nabs);
end $$;

create or replace function public.retard_valider(p_jour date, p_matricule text, p_retard boolean, p_heure text) returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if mon_role() not in ('direction','responsable_ops','coordinateur_ops','superviseur_principal','superviseur_nettoyage','superviseur_bagages','chef_nettoyage','chef_bagages') then raise exception 'Non autorisé'; end if;
  update statuts_jour set retard = p_retard, retard_heure = case when p_retard then p_heure else retard_heure end,
    retard_a_confirmer = false, saisi_par = auth.uid(), maj = now(),
    justification = case when p_retard then 'Retard confirmé' || coalesce(' — arrivée ' || p_heure, '') else coalesce(justification,'') || ' (absence confirmée)' end
  where jour = p_jour and matricule = p_matricule;
end $$;

create or replace function public.detecter_retards() returns int language plpgsql security definer set search_path to 'public' as $$
declare c record; n int := 0; nums text[]; dest uuid[];
begin
  if not appel_actif() then return 0; end if;
  for c in
    select s.jour, s.matricule, a.nom, a.badge, a.equipe, ev.submission_id
    from statuts_jour s join agents a on a.matricule = s.matricule
    join lateral (select x.submission_id from situation_staff x
                  where x.service = case when a.equipe like 'Manutention%' then 'bagages' else 'nettoyage' end
                    and substring(x.groupe from '(\d)\s*$') = right(a.equipe, 1)
                    and x.cree_le >= s.jour + time '16:00' and x.cree_le < s.jour + 1 + time '06:00'
                  order by x.cree_le desc limit 1) ev on true
    where s.statut = 'nj' and not s.retard and not s.retard_a_confirmer and s.saisi_par is null and s.jour >= current_date - 2
  loop
    select array_agg(m[1]) into nums from rapports_staff r, jsonb_each(r.brut->'answers') q, regexp_matches(coalesce(q.value->>'answer',''), '(\d{2,5})', 'g') m
     where r.submission_id = c.submission_id and q.value->>'text' ~* '(absence|cong)';
    if not (c.matricule = any(coalesce(nums,'{}')) or coalesce(c.badge,'#') = any(coalesce(nums,'{}'))) then
      update statuts_jour set retard_a_confirmer = true where jour = c.jour and matricule = c.matricule;
      select coalesce(array_agg(distinct x), '{}') into dest from (
        select fait_par x from appels where jour = c.jour and equipe = c.equipe and fait_par is not null
        union select p.id from profiles p join agents g on g.matricule = p.matricule where p.actif and g.equipe = c.equipe and p.role in ('chef_nettoyage','chef_bagages')) t;
      perform notifier(null, dest, 'presence', 'Retard à confirmer : ' || c.nom,
        c.nom || ' (ID ' || c.matricule || ') était absent(e) le matin et ne figure plus parmi les absents de la situation du soir. Confirmez le retard et l’heure d’arrivée (Mon shift).', 'shift', 'ret:' || c.jour || ':' || c.matricule);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

create or replace function public.rappels_appel() returns int language plpgsql security definer set search_path to 'public' as $$
declare j date := ((now() at time zone 'UTC') - interval '8 hours')::date; g int; e text; ids uuid[]; n int := 0; h time := (now() at time zone 'UTC')::time;
begin
  if not appel_actif() or (now() at time zone 'UTC')::date <> j or h < time '09:15' then return 0; end if;
  g := garde_du(j);
  foreach e in array array['Équipe ' || g, 'Manutention ' || g] || case when extract(isodow from j) <= 5 and h < time '16:00' then array['Équipe 4'] else '{}'::text[] end loop
    if exists (select 1 from appels where jour = j and equipe = e) then continue; end if;
    if not exists (select 1 from notifications where ref = 'ap1:' || j || ':' || e) then
      select array_agg(p.id) into ids from profiles p join agents a on a.matricule = p.matricule where p.actif and a.equipe = e and p.role in ('chef_nettoyage','chef_bagages');
      perform notifier(null, coalesce(ids,'{}'), 'rappel', 'Appel non fait : ' || e, 'L’appel de l’équipe n’a pas encore été fait dans l’app. Faites-le maintenant (Mon shift → Appel).', 'shift', 'ap1:' || j || ':' || e);
      n := n + 1;
    elsif h >= time '09:45' and not exists (select 1 from notifications where ref = 'ap2:' || j || ':' || e) then
      perform notifier(array[case when e like 'Manutention%' then 'superviseur_bagages' else 'superviseur_nettoyage' end, 'superviseur_principal'], null, 'rappel',
        '2e rappel : appel non fait (' || e || ')', 'L’appel n’est toujours pas fait. Relancez le chef d’équipe ou faites l’appel vous-même.', 'shift', 'ap2:' || j || ':' || e);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

grant execute on function public.appel_actif(), public.appel_enregistrer(date,text,jsonb,jsonb,double precision,double precision,double precision,text[],text[]),
  public.retard_valider(date,text,boolean,text) to authenticated;

select cron.schedule('presence-retards-rappels', '6-59/15 * * * *', $$select public.detecter_retards(); select public.rappels_appel();$$);

-- 19/11/2026 — Traitement des retards (migration retards_traitement_suite, appliquée) :
-- colonnes statuts_jour.retard_issue/retard_motif/retard_autorise_par/retard_traite_nom/retard_traite_le/
-- retard_suite/retard_suite_note/retard_suite_nom/retard_suite_le/retard_de_id ;
-- fonctions retard_traiter (retard + heure | absent | justifié/autorisé + motif + par qui, notification RH),
-- retard_suite_donner (informer RH | demande d'explication | avertissement verbal | autre, notification RH,
-- et superviseurs si un chef demande une DE), retard_de_lier (lien vers la demande d'explication établie).

-- 20/11/2026 — Justification / autorisation d'un retard ou d'une absence (appliqué) :
-- retard_traiter notifie RH + comptabilité pour une justification ; recap_paie ne la compte ni comme absence ni comme retard ;
-- trigger retard_justifie_clore : une justification clôt d'elle-même la « suite à donner » (aucune mesure).

-- 20/11/2026 — Prise de service et descente (migration prise_service_rappels, appliquée) :
-- prises_service.supplementaire ; table horaires_individuels (Ismail Niass 1101 : lundi→samedi 08h30–16h00, repos dimanche) ;
-- horaire_shift(matricule, jour) ; service_supplementaire() ; rappels_service() toutes les 15 min (cron rappels-prise-service) :
-- prise à l'heure prévue ; descente journée à l'heure de fin ; 24 h : 09h30 « n'oubliez pas de dépointer », 10h30 « descente ou shift supplémentaire ».

-- 20/11/2026 — Paie (migration grille_salaire_periode_essai, appliquée) : grille_salaire (notes de service n° 0016 et 0017),
-- salaire_base(matricule, date), recap_paie_mois(annee, mois), confirmations_essai + essais_verifier() (cron quotidien 06h20 :
-- au début du dernier mois de la période d'essai de 3 mois, notification RH + comptabilité) et essai_decider() (responsable de la comptabilité).

-- 20/11/2026 — Renforts (migrations renforts_heure_paie_appel_17h + situation_paie_correctif, appliquées) :
-- appel de 17h (colonnes appels.soir_*, appel_soir_enregistrer) ; heure d'arrivée obligatoire pour chaque renfort ;
-- tarif renfort dans grille_salaire (500 MRU par shift, quelle que soit l'heure d'arrivée) ; renforts_shifts(debut, fin) : un shift
-- compté une fois par agent (appel 08h, appel 17h, shift supplémentaire) ; situation_paie(annee, mois) = recap_paie_mois + shifts et montant des renforts.

-- 20/11/2026 — Onglet Comptabilité et congés (migration comptabilite_onglet_conges, appliquée) :
-- paie, grille, prêts/avances, primes réservés au responsable de la comptabilité, au responsable des opérations et à la direction ;
-- commande_compta() (validation comptable des demandes d'achat) ; table conges + conges_rappel() (cron du 20 au 28 à 07h41 :
-- planifier les congés du mois suivant avant le 1er) ; acces_ok() autorise les appels internes (tâches planifiées).

-- 20/11/2026 — Comptabilité par site (migrations compta_sites_ajustements, paie_site_correctif, paie_site_embauche, appliquées) :
-- table sites (AINO Nettoyage, AINO Manutention, AINO Nettoyage cabine, Sûreté nationale, Direction, CHN, ENAJM) ; agents.site + site_agent() ;
-- personnel_admin (salaires saisis par la comptabilité) ; paie_ajustements + paie_ajuster() (saisie dans l'app ou import Excel) ;
-- prets_avances.echeances_payees ; commandes.site, factures.site ; paie_site(annee, mois) (agents embauchés après la période exclus).

-- 2026-11-20 : retenue absences / mise à pied (paie_periode)
-- 500 MRU par jour d'absence non justifiée (hors retard) ou de mise à pied ;
-- un même jour n'est retenu qu'une fois. Grille : ('retenue','jour_absence_map',500).
-- Fonction paie_periode(p_annee, p_mois) = paie_site + jours_retenus, tarif_retenue, retenue_absences.
-- Webhook ITGHANE enregistré : app_secrets.itghane_webhook_url.

-- 2026-11-20 : demandes et documents de l'agent (fiche agent / annuaire)
create table if not exists public.demandes_agent (
  id bigserial primary key,
  ref text unique,
  matricule text not null,
  agent_nom text,
  nature text not null default 'demande' check (nature in ('demande','justificatif','autre')),
  type text not null check (type in ('permission_depart','permission_jours','pret','anticipation_conge','justificatif','autre')),
  objet text,
  date_debut date, date_fin date, heure_depart time, heure_retour time,
  nb_jours numeric, montant numeric, nb_echeances int,
  motif text, note text,
  statut text not null default 'en_attente' check (statut in ('en_attente','validee','refusee','annulee','depose')),
  lance_par uuid default auth.uid(), lance_nom text, lance_role text,
  created_at timestamptz not null default now(),
  sig_agent text, sig_agent_le timestamptz, sig_agent_par text,
  sig_sup text, sig_sup_nom text, sig_sup_le timestamptz,
  rh_decision text check (rh_decision in ('approuve','refuse')), rh_note text, rh_nom text, rh_le timestamptz,
  val_decision text check (val_decision in ('valide','refuse')), val_note text, val_nom text, val_le timestamptz,
  transmis_rh_le timestamptz,
  annule_nom text, annule_le timestamptz, annule_note text,
  pj jsonb not null default '[]'
);
create index if not exists demandes_agent_mat on public.demandes_agent(matricule, created_at desc);
create index if not exists demandes_agent_st on public.demandes_agent(statut);
alter table public.demandes_agent enable row level security;
create policy dem_r on public.demandes_agent for select to authenticated using (public.acces_ok(array['superviseur_nettoyage','superviseur_bagages','superviseur_principal','direction','responsable_ops','coordinateur_ops','responsable_rh','assistante_rh','responsable_comptabilite']));
create trigger zz_audit after insert or delete or update on public.demandes_agent for each row execute function audit_trig();
create trigger zz_flux after insert or delete or update on public.demandes_agent for each row execute function flux_trig('demandes_agent');

insert into storage.buckets (id, name, public) values ('dossiers-agents','dossiers-agents',false) on conflict (id) do nothing;
create policy dag_i on storage.objects for insert to authenticated with check (bucket_id = 'dossiers-agents' and public.mon_role() = any(array['superviseur_nettoyage','superviseur_bagages','superviseur_principal','direction','responsable_ops','coordinateur_ops','responsable_rh','assistante_rh']));
create policy dag_r on storage.objects for select to authenticated using (bucket_id = 'dossiers-agents' and public.mon_role() = any(array['superviseur_nettoyage','superviseur_bagages','superviseur_principal','direction','responsable_ops','coordinateur_ops','responsable_rh','assistante_rh','responsable_comptabilite']));

create or replace function public.dem_libelle(t text) returns text language sql immutable as $$
  select case t when 'permission_depart' then 'Permission de départ' when 'permission_jours' then 'Permission de quelques jours'
    when 'pret' then 'Demande de prêt' when 'anticipation_conge' then 'Demande d''anticipation de congé'
    when 'justificatif' then 'Justificatif d''absence' else 'Autre document' end $$;

create or replace function public.dem_manque(d public.demandes_agent) returns text language sql stable as $$
  select nullif(concat_ws(', ', case when d.sig_agent is null then 'signature de l''agent' end,
    case when d.sig_sup is null then 'signature du superviseur' end,
    case when d.rh_decision is null then 'approbation RH' end,
    case when d.val_decision is null then 'validation du responsable des opérations' end), '') $$;

create or replace function public.demande_creer(p jsonb) returns public.demandes_agent
language plpgsql security definer set search_path = public as $$
declare r public.demandes_agent; moi text := (select nom from profiles where id = auth.uid()); t text := p->>'type'; nat text; n int; pre text;
begin
  if not acces_ok(array['superviseur_nettoyage','superviseur_bagages','superviseur_principal','direction','responsable_ops','coordinateur_ops','responsable_rh','assistante_rh']) then raise exception 'Accès refusé'; end if;
  nat := case when t in ('justificatif','autre') then t else 'demande' end;
  if nat = 'demande' and not acces_ok(array['superviseur_nettoyage','superviseur_bagages','superviseur_principal','direction','responsable_ops','coordinateur_ops']) then
    raise exception 'Seuls les superviseurs, les superviseurs principaux et la direction peuvent lancer une demande'; end if;
  if not exists (select 1 from agents where matricule = p->>'matricule') then raise exception 'Agent introuvable'; end if;
  pre := case when nat = 'demande' then 'DEM' else 'DOC' end;
  select count(*) + 1 into n from demandes_agent where ref like pre || '-' || to_char(now(), 'YYYY') || '-%';
  insert into demandes_agent (ref, matricule, agent_nom, nature, type, objet, date_debut, date_fin, heure_depart, heure_retour, nb_jours, montant, nb_echeances, motif, note, statut, lance_nom, lance_role)
  values (pre || '-' || to_char(now(), 'YYYY') || '-' || lpad(n::text, 4, '0'), p->>'matricule', (select nom from agents where matricule = p->>'matricule'), nat, t,
    nullif(p->>'objet',''), nullif(p->>'date_debut','')::date, nullif(p->>'date_fin','')::date, nullif(p->>'heure_depart','')::time, nullif(p->>'heure_retour','')::time,
    nullif(p->>'nb_jours','')::numeric, nullif(p->>'montant','')::numeric, nullif(p->>'nb_echeances','')::int, nullif(p->>'motif',''), nullif(p->>'note',''),
    case when nat = 'demande' then 'en_attente' else 'depose' end, moi, mon_role())
  returning * into r;
  return r;
end $$;

create or replace function public.demande_notifier_creation(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare r public.demandes_agent;
begin
  select * into r from demandes_agent where id = p_id; if r.id is null or r.lance_par is distinct from auth.uid() then return; end if;
  if r.nature = 'demande' then
    perform notifier(array['responsable_ops','responsable_rh','assistante_rh'], null, 'rh', dem_libelle(r.type) || ' — ' || r.agent_nom || ' (à approuver)',
      'Lancée par ' || coalesce(r.lance_nom,'—') || coalesce(' · ' || to_char(r.date_debut,'DD/MM/YYYY'),'') || '. Manque : ' || coalesce(dem_manque(r),'rien') || '. Réf. ' || r.ref, 'eff', r.ref, auth.uid());
  else
    perform notifier(array['responsable_rh','assistante_rh'], null, 'rh', dem_libelle(r.type) || ' déposé — ' || r.agent_nom,
      coalesce(r.objet,'') || coalesce(' · ' || to_char(r.date_debut,'DD/MM/YYYY'),'') || ' · par ' || coalesce(r.lance_nom,'—') || '. Réf. ' || r.ref, 'eff', r.ref, auth.uid());
  end if;
end $$;

create or replace function public.demande_signer(p_id bigint, p_qui text, p_chemin text) returns public.demandes_agent
language plpgsql security definer set search_path = public as $$
declare r public.demandes_agent; moi text := (select nom from profiles where id = auth.uid());
begin
  if not acces_ok(array['superviseur_nettoyage','superviseur_bagages','superviseur_principal','direction','responsable_ops','coordinateur_ops']) then raise exception 'Accès refusé'; end if;
  select * into r from demandes_agent where id = p_id for update; if r.id is null then raise exception 'Demande introuvable'; end if;
  if r.statut <> 'en_attente' then raise exception 'La demande n''est plus en attente'; end if;
  if p_qui = 'agent' then update demandes_agent set sig_agent = p_chemin, sig_agent_le = now(), sig_agent_par = moi where id = p_id returning * into r;
  elsif p_qui = 'sup' then
    if r.lance_par is distinct from auth.uid() then raise exception 'Seul le superviseur qui a lancé la demande peut la signer'; end if;
    update demandes_agent set sig_sup = p_chemin, sig_sup_nom = moi, sig_sup_le = now() where id = p_id returning * into r;
  else raise exception 'Signataire inconnu'; end if;
  return r;
end $$;

create or replace function public.demande_rh(p_id bigint, p_decision text, p_note text default null) returns public.demandes_agent
language plpgsql security definer set search_path = public as $$
declare r public.demandes_agent; moi text := (select nom from profiles where id = auth.uid());
begin
  if not acces_ok(array['responsable_rh','assistante_rh']) then raise exception 'Réservé aux ressources humaines'; end if;
  if p_decision not in ('approuve','refuse') then raise exception 'Décision invalide'; end if;
  update demandes_agent set rh_decision = p_decision, rh_note = nullif(p_note,''), rh_nom = moi, rh_le = now()
   where id = p_id and nature = 'demande' and statut in ('en_attente','validee') returning * into r;
  if r.id is null then raise exception 'Demande introuvable ou close'; end if;
  perform notifier(array['responsable_ops'], array[r.lance_par], 'rh', dem_libelle(r.type) || ' — ' || r.agent_nom || ' : ' || case p_decision when 'approuve' then 'approuvée par les RH' else 'refusée par les RH' end,
    coalesce(p_note,'') || ' Réf. ' || r.ref, 'eff', r.ref, auth.uid());
  return r;
end $$;

create or replace function public.demande_valider(p_id bigint, p_decision text, p_note text default null) returns public.demandes_agent
language plpgsql security definer set search_path = public as $$
declare r public.demandes_agent; moi text := (select nom from profiles where id = auth.uid());
begin
  if not acces_ok(array['responsable_ops']) then raise exception 'Réservé au responsable des opérations'; end if;
  select * into r from demandes_agent where id = p_id for update;
  if r.id is null or r.nature <> 'demande' then raise exception 'Demande introuvable'; end if;
  if r.statut <> 'en_attente' then raise exception 'La demande n''est plus en attente'; end if;
  if p_decision = 'valide' and (r.sig_agent is null or r.sig_sup is null) then raise exception 'Signatures manquantes : %', concat_ws(', ', case when r.sig_agent is null then 'agent' end, case when r.sig_sup is null then 'superviseur' end); end if;
  if p_decision not in ('valide','refuse') then raise exception 'Décision invalide'; end if;
  update demandes_agent set val_decision = p_decision, val_note = nullif(p_note,''), val_nom = moi, val_le = now(),
    statut = case p_decision when 'valide' then 'validee' else 'refusee' end, transmis_rh_le = case p_decision when 'valide' then now() end
   where id = p_id returning * into r;
  perform notifier(array['responsable_rh','assistante_rh'], array[r.lance_par], 'rh',
    dem_libelle(r.type) || ' — ' || r.agent_nom || case p_decision when 'valide' then ' : validée, transmise aux RH' else ' : refusée' end,
    coalesce(p_note || ' ', '') || case when p_decision = 'valide' and r.rh_decision is null then 'Approbation RH encore attendue. ' else '' end || 'Réf. ' || r.ref, 'eff', r.ref, auth.uid());
  return r;
end $$;

create or replace function public.demande_annuler(p_id bigint, p_note text default null) returns public.demandes_agent
language plpgsql security definer set search_path = public as $$
declare r public.demandes_agent; moi text := (select nom from profiles where id = auth.uid());
begin
  select * into r from demandes_agent where id = p_id for update; if r.id is null then raise exception 'Introuvable'; end if;
  if not (r.lance_par = auth.uid() or acces_ok(array['responsable_ops','direction'])) then raise exception 'Seul l''auteur ou la direction peut annuler'; end if;
  if r.statut not in ('en_attente','depose') then raise exception 'Déjà traitée'; end if;
  update demandes_agent set statut = 'annulee', annule_nom = moi, annule_le = now(), annule_note = nullif(p_note,'') where id = p_id returning * into r;
  return r;
end $$;

create or replace function public.demande_pj(p_id bigint, p_item jsonb) returns public.demandes_agent
language plpgsql security definer set search_path = public as $$
declare r public.demandes_agent;
begin
  if not acces_ok(array['superviseur_nettoyage','superviseur_bagages','superviseur_principal','direction','responsable_ops','coordinateur_ops','responsable_rh','assistante_rh']) then raise exception 'Accès refusé'; end if;
  update demandes_agent set pj = pj || jsonb_build_array(p_item || jsonb_build_object('le', now(), 'par', (select nom from profiles where id = auth.uid())))
   where id = p_id and statut <> 'annulee' returning * into r;
  if r.id is null then raise exception 'Introuvable'; end if;
  return r;
end $$;

grant execute on function public.demande_creer(jsonb), public.demande_notifier_creation(bigint), public.demande_signer(bigint,text,text), public.demande_rh(bigint,text,text), public.demande_valider(bigint,text,text), public.demande_annuler(bigint,text), public.demande_pj(bigint,jsonb) to authenticated;

-- 2026-11-20 : intégration des demandes validées (situation, paie, congés, prêts) + priorité et écarts
alter table public.demandes_agent add column if not exists sig_dg text, add column if not exists verse_le date, add column if not exists verse_nom text,
  add column if not exists verse_note text, add column if not exists pret_id bigint, add column if not exists conge_id bigint,
  add column if not exists integre_le timestamptz, add column if not exists ecarts jsonb not null default '[]';

/* jour de shift concerné par une permission de départ (shift de 08h à 08h) */
create or replace function public.dem_jour_depart(d public.demandes_agent) returns date language sql immutable as $$
  select case when d.heure_depart is not null and d.heure_depart < time '08:00' then d.date_debut - 1 else d.date_debut end $$;

/* jour normalement travaillé par l'agent (rotation des équipes / jours ouvrés) */
create or replace function public.dem_jour_travaille(p_mat text, p_jour date) returns boolean language sql stable security definer set search_path = public as $$
  select case when a.service like 'Encadrement%' then true
    when a.equipe ~ '^(Équipe|Manutention) [123]$' then garde_du(p_jour) = right(a.equipe,1)::int
    when a.equipe in ('Équipe 4','Chauffeurs') then extract(isodow from p_jour) <= 5
    else true end from agents a where a.matricule = p_mat $$;

create or replace function public.dem_ecart(p_id bigint, p_jour date, p_txt text) returns void
language plpgsql security definer set search_path = public as $$
declare r public.demandes_agent;
begin
  select * into r from demandes_agent where id = p_id;
  if r.ecarts @> jsonb_build_array(jsonb_build_object('jour', p_jour, 'texte', p_txt)) then return; end if;
  update demandes_agent set ecarts = ecarts || jsonb_build_array(jsonb_build_object('jour', p_jour, 'texte', p_txt, 'le', now())) where id = p_id;
  perform notifier(array['responsable_rh','assistante_rh'], null, 'presence', 'Écart avec une ' || lower(dem_libelle(r.type)) || ' — ' || r.agent_nom,
    to_char(p_jour,'DD/MM/YYYY') || ' : ' || p_txt || ' La ' || lower(dem_libelle(r.type)) || ' validée (' || r.ref || ') a été appliquée.', 'eff', r.ref, null);
end $$;

/* priorité des permissions et congés validés sur la situation saisie (appel, situation du staff, saisie manuelle) */
create or replace function public.dem_priorite() returns trigger
language plpgsql security definer set search_path = public as $$
declare d public.demandes_agent; x text; src text; lib text := case coalesce(new.statut, old.statut) when 'nj' then 'absent non justifié' when 'j' then 'absence justifiée' when 'c' then 'congé' when 'mp' then 'mise à pied' else 'présent' end;
begin
  if coalesce(current_setting('eps.dem_sync', true), '') = '1' then return coalesce(new, old); end if;
  if tg_op = 'DELETE' then
    select * into d from demandes_agent where matricule = old.matricule and statut = 'validee' and type in ('permission_jours','anticipation_conge') and old.jour between date_debut and date_fin limit 1;
    if d.id is null then return old; end if;
    perform dem_ecart(d.id, old.jour, 'l''agent a été marqué présent dans la situation' || coalesce(' par ' || (select nom from profiles where id = auth.uid()), '') || '.');
    return null;
  end if;
  select * into d from demandes_agent where matricule = new.matricule and statut = 'validee'
    and ((type in ('permission_jours','anticipation_conge') and new.jour between date_debut and date_fin) or (type = 'permission_depart' and dem_jour_depart(demandes_agent) = new.jour)) limit 1;
  if d.id is null then return new; end if;
  x := case d.type when 'permission_jours' then 'j' when 'anticipation_conge' then 'c' end;
  if tg_op = 'UPDATE' and new.statut is not distinct from old.statut then return new; end if;
  src := case when new.justification like 'Jotform%' then ' dans la situation du staff (Jotform)' else coalesce(' par ' || (select nom from profiles where id = auth.uid()), '') end;
  if x is null then /* permission de départ : l'agent était présent */
    if new.statut = 'nj' then
      perform dem_ecart(d.id, new.jour, 'l''agent a été marqué « absent non justifié »' || src || '.');
      if tg_op = 'INSERT' then return null; else return old; end if;
    end if;
    return new;
  end if;
  if new.statut = x then return new; end if;
  if new.statut = 'mp' then perform dem_ecart(d.id, new.jour, 'une mise à pied couvre ce jour ; elle est conservée, à vérifier.'); return new; end if;
  perform dem_ecart(d.id, new.jour, 'l''agent a été marqué « ' || lib || ' »' || src || '.');
  new.statut := x; new.justification := dem_libelle(d.type) || ' validée — ' || d.ref;
  return new;
end $$;
create trigger dem_priorite before insert or update or delete on public.statuts_jour for each row execute function dem_priorite();

/* intégration à la situation (et donc à la paie) d'une permission ou d'un congé anticipé validé */
create or replace function public.dem_integrer(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare r public.demandes_agent; x text; j date; o text; cid bigint;
begin
  select * into r from demandes_agent where id = p_id;
  if r.statut <> 'validee' or r.type not in ('permission_jours','anticipation_conge') or r.date_debut is null then return; end if;
  x := case r.type when 'permission_jours' then 'j' else 'c' end;
  perform set_config('eps.dem_sync', '1', true);
  for j in select g::date from generate_series(r.date_debut, coalesce(r.date_fin, r.date_debut), interval '1 day') g loop
    if not dem_jour_travaille(r.matricule, j) then continue; end if;
    select statut into o from statuts_jour where jour = j and matricule = r.matricule;
    if o = 'mp' then perform dem_ecart(r.id, j, 'une mise à pied couvre ce jour ; elle est conservée, à vérifier.'); continue; end if;
    if o is not null and o <> x then perform dem_ecart(r.id, j, 'la situation indiquait « ' || case o when 'nj' then 'absent non justifié' when 'j' then 'absence justifiée' when 'c' then 'congé' else o end || ' » avant la validation.'); end if;
    insert into statuts_jour (jour, matricule, statut, justification, saisi_par, maj) values (j, r.matricule, x, dem_libelle(r.type) || ' validée — ' || r.ref, auth.uid(), now())
      on conflict (jour, matricule) do update set statut = excluded.statut, justification = excluded.justification, saisi_par = excluded.saisi_par, maj = now();
  end loop;
  perform set_config('eps.dem_sync', '', true);
  if r.type = 'anticipation_conge' then
    insert into conges (matricule, date_debut, date_fin, type, statut, motif, cree_par, cree_nom, valide_par, valide_nom, valide_le)
    values (r.matricule, r.date_debut, coalesce(r.date_fin, r.date_debut), 'annuel', 'valide', 'Anticipation de congé — ' || r.ref || coalesce(' : ' || r.motif, ''), r.lance_par, r.lance_nom, auth.uid(), r.val_nom, now()) returning id into cid;
  end if;
  update demandes_agent set integre_le = now(), conge_id = coalesce(cid, conge_id) where id = p_id;
end $$;

create or replace function public.dem_apres_validation(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare r public.demandes_agent;
begin
  select * into r from demandes_agent where id = p_id;
  if r.type = 'pret' then
    perform notifier(array['responsable_comptabilite'], null, 'rh', 'Prêt à verser — ' || r.agent_nom, coalesce(r.montant::text,'?') || ' MRU en ' || coalesce(r.nb_echeances,1) || ' échéance(s). Confirmez le versement pour l''ajouter à la paie. Réf. ' || r.ref, 'eff', r.ref, null);
  else perform dem_integrer(p_id); end if;
end $$;

/* RH : facultatif pour permissions et congés, obligatoire pour les prêts */
create or replace function public.demande_rh(p_id bigint, p_decision text, p_note text default null) returns public.demandes_agent
language plpgsql security definer set search_path = public as $$
declare r public.demandes_agent; moi text := (select nom from profiles where id = auth.uid());
begin
  if not acces_ok(array['responsable_rh','assistante_rh']) then raise exception 'Réservé aux ressources humaines'; end if;
  if p_decision not in ('approuve','refuse') then raise exception 'Décision invalide'; end if;
  update demandes_agent set rh_decision = p_decision, rh_note = nullif(p_note,''), rh_nom = moi, rh_le = now()
   where id = p_id and nature = 'demande' and statut in ('en_attente','validee') and rh_decision is null returning * into r;
  if r.id is null then raise exception 'Demande introuvable, close ou déjà traitée par les RH'; end if;
  if r.type = 'pret' and r.statut = 'en_attente' then
    if p_decision = 'refuse' then update demandes_agent set statut = 'refusee' where id = p_id returning * into r;
    elsif r.val_decision = 'valide' then update demandes_agent set statut = 'validee', transmis_rh_le = now() where id = p_id returning * into r; perform dem_apres_validation(p_id); end if;
  end if;
  perform notifier(array[case when r.type = 'pret' then 'direction' else 'responsable_ops' end], array[r.lance_par], 'rh', dem_libelle(r.type) || ' — ' || r.agent_nom || ' : ' || case p_decision when 'approuve' then 'approuvée par les RH' else 'refusée par les RH' end,
    coalesce(p_note || ' ','') || 'Réf. ' || r.ref, 'eff', r.ref, auth.uid());
  return r;
end $$;

/* validation finale : responsable des opérations (permissions, congés) ; DG pour les prêts (avec l'approbation RH) */
create or replace function public.demande_decider(p_id bigint, p_decision text, p_note text default null, p_sig text default null) returns public.demandes_agent
language plpgsql security definer set search_path = public as $$
declare r public.demandes_agent; moi text := (select nom from profiles where id = auth.uid());
begin
  select * into r from demandes_agent where id = p_id for update;
  if r.id is null or r.nature <> 'demande' then raise exception 'Demande introuvable'; end if;
  if r.type = 'pret' then if not acces_ok(array['direction']) then raise exception 'Les prêts sont validés et signés par la Direction générale'; end if;
  elsif not acces_ok(array['responsable_ops']) then raise exception 'Réservé au responsable des opérations'; end if;
  if r.statut <> 'en_attente' or r.val_decision is not null then raise exception 'La demande n''est plus en attente'; end if;
  if p_decision not in ('valide','refuse') then raise exception 'Décision invalide'; end if;
  if p_decision = 'valide' and (r.sig_agent is null or r.sig_sup is null) then raise exception 'Signatures manquantes : %', concat_ws(', ', case when r.sig_agent is null then 'agent' end, case when r.sig_sup is null then 'superviseur' end); end if;
  if p_decision = 'valide' and r.type = 'pret' and p_sig is null then raise exception 'La signature de la Direction générale est requise'; end if;
  update demandes_agent set val_decision = p_decision, val_note = nullif(p_note,''), val_nom = moi, val_le = now(), sig_dg = case when r.type = 'pret' then p_sig else sig_dg end,
    statut = case when p_decision = 'refuse' then 'refusee' when r.type = 'pret' and coalesce(r.rh_decision,'') <> 'approuve' then 'en_attente' else 'validee' end,
    transmis_rh_le = case when p_decision = 'valide' and (r.type <> 'pret' or r.rh_decision = 'approuve') then now() end
   where id = p_id returning * into r;
  if r.statut = 'validee' then perform dem_apres_validation(p_id); end if;
  perform notifier(array['responsable_rh','assistante_rh'], array[r.lance_par], 'rh',
    dem_libelle(r.type) || ' — ' || r.agent_nom || case when p_decision = 'refuse' then ' : refusée' when r.statut = 'validee' then ' : validée, transmise aux RH' else ' : signée par la DG, approbation RH attendue' end,
    coalesce(p_note || ' ', '') || case when r.statut = 'validee' and r.type <> 'pret' then 'Intégrée à la situation et à la paie. ' else '' end || 'Réf. ' || r.ref, 'eff', r.ref, auth.uid());
  return r;
end $$;

/* comptabilité : confirmation du versement du prêt -> ligne dans Prêts et avances -> retenues sur la paie */
create or replace function public.demande_versement(p_id bigint, p_date date, p_debut_periode date, p_note text default null) returns public.demandes_agent
language plpgsql security definer set search_path = public as $$
declare r public.demandes_agent; moi text := (select nom from profiles where id = auth.uid()); pid bigint; dp date;
begin
  if not acces_ok(array['responsable_comptabilite']) then raise exception 'Réservé au responsable de la comptabilité'; end if;
  select * into r from demandes_agent where id = p_id for update;
  if r.id is null or r.type <> 'pret' or r.statut <> 'validee' then raise exception 'Prêt non validé'; end if;
  if r.verse_le is not null then raise exception 'Versement déjà confirmé'; end if;
  dp := case when extract(day from p_debut_periode) >= 26 then make_date(extract(year from p_debut_periode)::int, extract(month from p_debut_periode)::int, 26)
             else (make_date(extract(year from p_debut_periode)::int, extract(month from p_debut_periode)::int, 26) - interval '1 month')::date end;
  insert into prets_avances (matricule, type, montant, date_octroi, nb_echeances, debut_periode, motif, accorde_par, statut, note, cree_par, cree_nom, echeances_payees)
  values (r.matricule, 'pret', r.montant, p_date, coalesce(r.nb_echeances, 1), dp, r.motif, r.val_nom, 'en_cours', 'Demande ' || r.ref || coalesce(' — ' || nullif(p_note,''), ''), auth.uid(), moi, 0) returning id into pid;
  update demandes_agent set verse_le = p_date, verse_nom = moi, verse_note = nullif(p_note,''), pret_id = pid where id = p_id returning * into r;
  perform notifier(array['responsable_rh','assistante_rh','direction'], array[r.lance_par], 'rh', 'Prêt versé — ' || r.agent_nom,
    r.montant || ' MRU versés le ' || to_char(p_date,'DD/MM/YYYY') || ', retenus en ' || coalesce(r.nb_echeances,1) || ' échéance(s) à partir de la paie de la période commençant le ' || to_char(dp,'DD/MM/YYYY') || '. Réf. ' || r.ref, 'eff', r.ref, auth.uid());
  return r;
end $$;
create or replace function public.demande_valider(p_id bigint, p_decision text, p_note text default null) returns public.demandes_agent
language sql security definer set search_path = public as $$ select demande_decider(p_id, p_decision, p_note, null) $$;
grant execute on function public.demande_versement(bigint,date,date,text), public.demande_decider(bigint,text,text,text) to authenticated;

create or replace function public.dem_manque(d public.demandes_agent) returns text language sql stable as $$
  select nullif(concat_ws(', ', case when d.sig_agent is null then 'signature de l''agent' end,
    case when d.sig_sup is null then 'signature du superviseur' end,
    case when d.type = 'pret' and d.rh_decision is null then 'approbation RH' end,
    case when d.val_decision is null then case when d.type = 'pret' then 'signature de la DG' else 'validation du responsable des opérations' end end), '') $$;


-- 2026-11-21 : chevauchements interdits (migration demandes_chevauchement)
-- dem_chevauchement(matricule, debut, fin) : demande de permission/congé en attente ou validée, ou congé planifié, sur ces dates.
-- demande_creer refuse « Ces dates sont déjà couvertes : … ».

-- 2026-11-21 : prolongation et retour anticipé (migration demandes_retour_prolongation)
-- demandes_agent : prolonge_de, date_fin_initiale, retour_le, retour_nom, retour_motif ; conges : date_fin_initiale, retour_nom, retour_motif.
-- retour_anticipe(matricule, jour_de_reprise, motif) : la permission / le congé s'arrête la veille, situation et paie corrigées, RH + resp. ops notifiés.

-- 2026-11-21 : dossier de l'agent (migration dossier_agent_evaluations_parcours_documents)
-- dos_visible(matricule) : chef = son dossier ; superviseur = chefs et agents de son service ; sup. principal, direction, RH, compta = tous.
-- evaluations_agents + evaluations_agents_calculer (cron evaluations-agents-mensuelles, le 26) : 80 % présence + 20 % ponctualité − 10 pts / dossier disciplinaire.
-- parcours_agent (+ trigger parcours_agent_auto sur agents : fonction → promotion/régression/changement de poste ; équipe/service/zone → affectation).
-- documents_agent (pièce d'identité, photo, casier judiciaire, badge, formation, contrat, autre) ; stockage dossiers-agents/agents/<matricule>/.

-- 2026-11-22 : signalements — rappel_vols(texte, ref) : notification « vols en cours ou proches » aux chefs d'équipe et superviseurs.
-- Fonction ia-texte : fournisseur OpenAI (OPENAI_API_KEY) ou Anthropic ; mode signalement : destinataire interne/externe, vols proches, a_preciser.

-- 2026-11-22 : performance — vue situation_staff limitée aux formulaires qui contiennent une situation du staff
-- (nettoyage, bagages, shift_ops) et protégée contre les réponses d'erreur Jotform (answers non objet) ;
-- index rapports_staff(service, recu_le). Requêtes situation_staff / rapports_detail : de 1,3–1,7 s à 4–12 ms.

-- 2026-11-22 : accès (migrations acces_coordinateur_compta_tech_appro_signalements, paie_ajuster_coordinateur)
-- coordinateur_ops : comptabilité (prêts, primes, grille, personnel admin, ajustements, factures, fonctions de paie).
-- responsable_technique, approvisionnement : création et lecture des signalements, pièces jointes, historique.

-- 2026-11-22 : marquer_taches_auto compare le numéro d'équipe (les situations Jotform indiquent « Équipe M3 », plus « Groupe 3 ») ;
-- cron taches-reguliere-auto toutes les 5 min ; tc_r : tâches personnelles visibles seulement par la personne, l'auteur
-- et direction / responsable / coordinateur des opérations.

-- 2026-11-22 : tâches (migration taches_cloture_remontees_photos) — colonnes de clôture (texte, lieu, GPS, auteur, RAS),
-- taches_remontees (incidents / informations, plusieurs par shift), taches_pj + stockage taches-pj (photos avant / après / remontées),
-- tache_cloturer(), modèle n_remontee_incidents (nettoyage), échéance à la descente. ia-texte : mode « transcrire » (OpenAI).

-- 2026-11-22 : marquer_taches_auto v2 — rattachement au « Début du shift » du formulaire (jf_debut) ; situation 17h = rapport avec
-- nombre de renforts renseigné (0 ou plus) qui n'est pas le premier du shift, ou rapport envoyé après 13h ; taches.rapport_sub = soumission liée.

-- v43 : interventions pas à pas — table taches_etapes (demarrage GPS / position_refusee / photos_avant / pause / reprise / photos_apres / cloture),
--        taches_pj + pris_le, precision_m ; bucket taches-pj 100 Mo (vidéos). Photos horodatées + géolocalisées (incrustation), consultation avec déroulé et SLA.

-- v44 : PDF discipline nommés « MAP - Nom de l agent - référence » / « DE - Nom de l agent - référence » (téléchargement, partage, impression).

-- v45 : identifiant numérique (doc_hash) retiré du document imprimé, affiché dans l application (Discipline) avec l auteur, sa fonction et la date.

-- v47 : écran Évaluations mensuelles (revue SP → validation resp. ops → RH) depuis Mon profil / Tâches ; Journal des modifications (audit_journal) depuis Mon profil (resp. ops, direction).

-- v48 : évaluation de l encadrement (eval_enc, eval_enc_avis, eval_enc_lancer/auto/enreg/avis_enreg/signer/stats), cron evaluations-encadrement 15/03,06,09,12 07h37 (S2-2026 le 15/12/2026), evaluations mensuelles visibles par chefs/superviseurs seulement après partage (partage_le), bucket discipline : chemins ee/.

-- v52 : taches.demarre_le/demarre_nom (trigger taches_demarrage) ; renommage modeles n_appel, n_situation_0930, situation_0930 (09h30), n_dispatch (09h30 → 10h00) ; liste des tâches minimaliste.

-- v53 : renommage des tâches régulières ; rapports_vols / rapports_wchr désactivés (uniquement par vol) ; fiche de nettoyage cabine par vol (MAI pour L6, Afroport sinon) préremplie ; trigger rs_cabin_lier (rattachement des fiches cabine à leur vol).

-- v54 : comptes_rendus (jour/semaine/mois) + fonction compte-rendu (IA) + crons 08h41 / lundi 09h13 / 1er 09h23 ; cr_donnees_jour, cr_donnees_periode, cr_demander ; rapports_staff.envoye_le (heure exacte d envoi Jotform) ; tâches par vol vol_cc (fiche cabine) ; compagnie / type d appareil Afroport par correspondance.

-- v55 : rs_vol() (rapport de vol / fiche cabine : rattachement direct ou n° cité, rotations comptées pour les 2 vols) ; lier_rapports_vols préfère les vols radar ; retard des rotations mesuré après le départ.

-- v55b : notifications vol — ids_vol(), msg_vol_notif (PSM / LDM reçus, trigger messages_vol), rappels_approche (cron */5, 40 min avant l arrivée).

-- v57 : signalement en 2 étapes (description + enregistrement IA + photos ; lieu repéré automatiquement, champs facultatifs), message Help Desk réduit, rapport d incident depuis des signalements (incident_reports.signalements).

-- v58 : signalements.urgence (ligne d urgence brève, ajoutée au message Help Desk).

-- v60 : signalements de zone (internes) : même méthode en 2 étapes (description + enregistrement IA + photos ; zone, lieu et nature repérés) ; signalements_zone.photos.

-- v61 : volet Ressources humaines (cartes Suivi présence / Discipline / Effectifs, filtre site et service, À traiter) ; appel : encadrement tiré de l annuaire ; conges_sans_decision_liste / _alerte (cron 09h17, RH notifiées).
