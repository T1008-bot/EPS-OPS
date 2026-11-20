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
