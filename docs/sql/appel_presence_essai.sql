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

-- v62 : approvisionnement (Ndey Ba) = mêmes droits RH que l assistante RH : 40 politiques RLS, 28 fonctions, listes de rôles de l app, fonction drive.

-- v63 : approvisionnement = mêmes droits que la responsable comptabilité (politiques, fonctions, listes de rôles, onglet Comptabilité).

-- v65 : discipline — DE pour RH/approvisionnement/comptabilité ; délégation Direction (générale ou nominative), son superviseur, son chef d équipe, autre ; AVT/MAP et refus confiés à la direction (discipline.delegue_dir).

-- v66 : sites ASECNA, MIF, Ministère du Pétrole, UNPM ; personnel_admin + tel/source (42 personnes des sites ville, Equipes Ville - NKC.xlsx) ; paie_site groupe « Équipe ville » ; collecte-import (Drive Collecte infos → tel/badge/NNI/date par rapprochement de nom) ; paie : saisie sur place + colonne téléphone.

-- v67 : agent_ajouter (matricule auto 1330-1399 N, 1490-1600 M), agent_modifier, agent_depart (arrêt paie, compta + équipe notifiées), ids_equipe, agent_matricule_suivant ; agents + civilite/date_naissance/contact_urgence/motif_depart ; paie_site exclut les partis avant la période ; UI : Consulter / Mettre à jour (recrue, départ), fiche modifiable, anciens employés, départs à confirmer Valider / Modifier la date, classeur Drive (ajout, modification, départ → ex-employés).

-- v67b : fonction jf-form (listes de matricules des formulaires Situation du staff, mises à jour via l API Jotform) + jf_sync() appelée par agent_ajouter / agent_modifier / agent_depart.

-- v70 (23/11/2026) : site aino_cabine désactivé (nettoyage cabine = équipes Nettoyage 24 h) ;
-- badges vides des agents de l'aéroport = 'Sans Badge' ; badge masqué pour les sites ville (sauf ASECNA) ;
-- matricules ville : 1130 Ramatoulaye (ENAJM), 1131 Salyata Gueye (DGSN), DGSN 1601-1650, ENAJM 1651-1680,
-- MIF 1681-1690, Pétrole 1691-1700 (agent_matricule_suivant accepte surete/enajm/mif/petrole).

-- v71 (23/11/2026) : bons de dotation Magasin Ville → magasins des sites.
-- magasins.site/central/actif (Ville = central ; magasins créés pour ASECNA, DGSN, ENAJM, CHN, MIF, Pétrole, UNPM),
-- articles.categorie, dotation_quotas, dotations (lignes jsonb dem/acc/rec, signatures remis/validé/reçu),
-- dotation_enregistrer / dotation_valider / dotation_expedier (sortie Ville) / dotation_recevoir (entrée site).
-- Réception ouverte provisoirement à approvisionnement (Ndey) et responsable_comptabilite (Abderahmane).

-- v72 (23/11/2026) : magasins — central (Ville), aéroport extérieur (réserve) / intérieur (côté piste), sites.
-- Catalogue repris du formulaire Jotform 263073141001035 (23 articles) ; article_ajouter (articles absents : machines, outils…).
-- mouvement_saisir : entrées (réception fournisseur, retours) et sorties avec destination (Terminal, Bât. admin et annexe, Fret,
-- Mosquée, Pavillon présidentiel, ASECNA comptée à part via site_conso) ; ravitaillement extérieur → intérieur automatique.
-- bilan_enregistrer (inventaire signé, ajustements) ; conso_analyse (moyenne dès 3 jours, dépassement grave / hausse / chute) ;
-- crons bilan-magasin-interieur 09:00 (tâche Abderahmane, clôturée par le bilan) et conso-magasin-alertes 21:07.

-- v73 (24/11/2026) : plus de bilan quotidien (stock calculé par les entrées/sorties) ; cron bilan-magasins-aeroport
-- vendredi 08:13, semaines ISO paires (1er le 27/11) : tâches à Ismail Niass, notification aux superviseurs principaux,
-- Ismail Niass et responsable des opérations. Abderahmane : magasin central uniquement (mouvement_saisir / bilan_enregistrer).
-- magasin_seuils + seuil_alertes + trigger mv_seuil (seuil_controle) : alerte urgente ; aéroport → superviseurs principaux,
-- Ismail Niass, approvisionnement + tâche « Expression de besoin » (besoin_seuil:m:a) ; central/sites → approvisionnement,
-- comptabilité. Trigger bs_seuil : l'expression de besoin clôt les tâches d'alerte.

-- v74 (24/11/2026) : maquettes validées — tâches « Situation du staff » (une à la fois, faite = retirée, 17 h affichée à 17 h,
-- cron situation-17h-notif → chefs de garde), titre « Planning du jour : tâches & missions », cartes Observations / Instances /
-- Retards + journal du shift (table shift_observations), statistiques de vol Manutention et Nettoyage (stats_vols, rs_ans,
-- rs_heure, apres ; retard = off block − départ prévu allocation/programme, cause du rapport ou vol_retard_justif),
-- alerte rouge Help Desk « sans N° de ticket », colonne « Lancé par », bouton « Saisir le ticket ».
-- Retour arrière : git revert de ce commit ; select cron.unschedule('situation-17h-notif').

-- v75 (24/11/2026) : profiles.poste (intitulé affiché, indépendant du rôle) ; Ndey Ba = Responsable des relations extérieures (rôle approvisionnement inchangé).

-- v76 (24/11/2026) : messagerie — conversations / conv_membres (retire au lieu de suppression) / messages (temps réel),
-- msg_cat + msg_peut_ecrire (chef↔chef, chef↔sup, sup↔sup, chef/sup↔SP, SP↔SP, tous↔responsable des opérations,
-- consultant↔SP/sup/direction/coordinateur, direction↔coordinateur/SP), groupes Ops Nettoyage / Ops Manutention / Ops Superviseurs
-- tenus à jour par trigger sur profiles (msg_groupes_sync), msg_direct, msg_envoyer (notification catégorie « messages »),
-- msg_liste, msg_lu, msg_lu_par, stockage messages-pj. Client : bulle flottante permanente, panneau, onglet Messages,
-- demande d'autorisation des notifications à l'ouverture tant qu'elle n'est pas accordée.

-- v77 (24/11/2026) : paie — retenue par jour d’absence non justifiée / mise à pied = salaire mensuel / 30 (au lieu de 500 MRU) ;
-- prorata arrivée / départ en cours de période = salaire / 30 × jours de présence (date d’embauche et date de départ incluses), observation « Prorata ».

-- 24/11/2026 : salaire_base — date d’embauche manquante = tarif ancien agent / ancien chef (plus de salaire à 0) ; tâche EPS/OPS/TCH/2026/450 à la comptabilité (44 saisies manuelles ≠ grille).

-- v78 (24/11/2026) : messages.supprime_le + msg_supprimer (auteur seulement, effacement du contenu, « Message supprimé ») ; depenses_diverses (onglet Comptabilité « Dépenses diverses », justificatif dans commandes-pj/depenses, annulation sans suppression).

-- v79 (24/11/2026) : bulle de messagerie masquée pendant les fenêtres et les confirmations, onglet latéral sur téléphone ; ia-texte « corriger » → reformulation claire, simple et professionnelle (bouton « Améliorer le texte ») ;
-- rapports_financiers + fin_donnees(annee, mois) + fonction rapport-financier (IA) + cron rapport-financier-mensuel le 26 à 09:41 → responsable et directeur des opérations ; affichage dans Mon profil.

-- v80 (24/11/2026) : agent 1128 Mamadou Amadou Sy, chef d’équipe manutention en rotation (équipe « Manutention (rotatif) », matricule à confirmer) ; jf-form : détail des erreurs d’écriture Jotform ; personnel_admin Ndey Ba = Responsable des relations extérieures.

-- v81 (24/11/2026) : paie v3 (sélection Tout / Aéroport global / Nettoyage / Manutention / ASECNA / Opérations aéroport / Direction & administration / Sites ville / chaque site ; blocs avec cartes d’équipe dépliables ; total général) ; RH : carte « Encadrement » (superviseurs / chefs d’équipe).

-- v82 (24/11/2026) : trigger agents_dossier (agent_dossier_controle) : nouvelle fiche incomplète → tâche RH « Dossier à compléter » + notification RH, clôture auto quand date d’embauche, téléphone et NNI sont renseignés ; tâche créée pour 1128 ; tableau de bord RH : « Dossier à compléter » pour les fiches de moins de 60 jours ; effectif prévu équipe 4 = 34.

-- v83 (24/11/2026) : superviseurs nettoyage comptés dans l’effectif de l’équipe 4 ; trigger agents_jf_sync (insert / changement d’équipe, statut, fonction, nom, matricule → jf_sync) + cron jotform-listes-sync 07:47.

-- v84 (24/11/2026) : table vehicules (VEH-01..03, BAL-01..02, BUS-01..05, NAC-01 ; immatriculations et chauffeurs de la facture carburant) ; depenses_diverses.vehicule ; catégories carburant, maintenance véhicule, badges et macarons, nourriture / cuisine.

-- v85 (25/11/2026) : msg_gestionnaire (responsable, directeur, coordinateur des opérations hors consultant) ; msg_groupe_creer / msg_groupe_modifier / msg_membres / msg_annuaire (groupes libres, membres ajoutés / retirés, groupes Ops automatiques non modifiables) ; rapports financiers aussi pour le coordinateur des opérations (RLS + notification) ; flotte : BUS-02 Cheikh Dahane, BUS-04 Souleymane Kalilou Ndiaye, NAC-01 ciseaux / NAC-02 bras articulé (Moussa Demba Traoré).

-- v86 (25/11/2026) : 1330 doublon retiré (départ au 25/10) ; consultant : rapports financiers ; salaire_base : tarif confirmé après validation de la comptabilité et après la fin du mois d’échéance de l’essai ; essais_verifier crée une tâche à la comptabilité, close par la décision (trigger confirmations_essai_tache) ; départ « transfert » : choix changement d’affectation (fiche) ou départ définitif.

-- v87 (25/11/2026) : profiles.email (7 comptes ITGHANE rapprochés) + login_par_email (connexion par e-mail ou téléphone) ; ITGHANE → EPS OPS : fonction itghane-entrant + table itghane_entrees (comptes, documents, signatures) ; côté ITGHANE (projet Progiciel EPS) : pg_net, eps_ops_envoyer et intégration de tous les jeux reçus ; formulaire Jotform 263073141001035 désactivé.

-- v88 (2026-11-25) : correction du N° BDM (signalements externes)
-- RPC sig_bdm_modifier(p_id, p_bdm, p_motif) + sig_bdm_auteur(p_id) : autorisé à l'auteur de la saisie BDM
-- (ou au créateur du signalement si aucune saisie tracée), aux superviseurs principaux, responsables des opérations
-- et superviseurs. Trace l'ancien/nouveau numéro et le motif dans un événement 'commentaire'. Aucune suppression.

-- v89 (2026-11-25) : historique des corrections BDM confidentiel
-- Table sig_bdm_corrections (ancien, nouveau, motif, par_nom, date), RLS : equipe_ops() ou auteur de la correction.
-- equipe_ops() = responsable_ops, coordinateur_ops (dont consultant RH & opérations), superviseur_principal,
-- direction avec poste 'Directeur des opérations' (Sidahmed Labeid). sig_bdm_modifier n'écrit plus dans la chronologie publique.

-- 2026-11-25 : notification « N° BDM saisi » → équipe opération uniquement
-- equipe_ops_ids() + trigger nt_sig_bdm (after update of bdm on signalements) : quand un signalement reçoit son 1er N° BDM,
-- notifier(null, equipe_ops_ids(), 'helpdesk', '🎫 BDM … — réf.', objet · zone · saisi par …, 'sig', id, sauf = auteur).
-- Les corrections ultérieures du numéro ne déclenchent pas de notification.

-- v90 (2026-11-25) : profil « Ndey Ba » renommé « Ndeye Diaty Ba » (+ libellé CM_DEST).

-- v91 (2026-11-25) : rapprochement badges / matricules
-- Fiche 1330 (doublon de 1317 Cheikh Dahane M'Bareck, même NNI) supprimée avec son parcours (demande explicite).
-- agents.tel_a_verifier (1203, 1450, 1482 ; 1319 numéro retiré, à renseigner) + tâches RH modele 'tel:<matricule>'
--   (triggers agents_tel_verif / agents_tel_verif_tache : clôture quand le numéro est corrigé ou confirmé).
-- agents.masque_listes (1250D, 1460D) : exclus de paie_site, visibles dans « Anciens employés ».
-- statuts_jour 1250 avant 10/11 → 1250D (absences de Kawa Hemetth Seck) ; absence 1460 du 18/11 supprimée (réaffecté au 19).
-- Badge 188 = 1429 Foussou Mamadou Niakhaté ; 1465 Bilal Mohamed → Sans Badge en attente (2431 déjà porté par 1463).

-- v92 (2026-11-25) : saisie et dictée
-- Bug : les zones de texte des fenêtres portaient data-vx (marqueur des cartes de vols) → Espace et Entrée bloqués
--   (demandes d'explication, mises à pied, signalements, tâches…). Marqueur renommé data-vxt / data-novx.
-- Après une dictée ou un enregistrement, le texte est consolidé et enrichi par l'IA (retour au texte dicté possible).
-- Objet / titre déduit du texte (data-objet) : DE, MAP manuelle, signalement, tâche ; MAP/AVT reprennent l'objet de la DE
--   (affiché dans la décision ; MAP manuelle avec référence de DE → objet de la DE).
-- ia-texte v12 : mode « corriger » enrichit selon le type de document, nouveau mode « objet », objet fixé dans les décisions,
--   vocabulaire métier pour la transcription (source : docs/functions/ia-texte/index.ts).

-- v93 (2026-11-25) : expression de besoin multi-articles
-- besoins.unite, besoins.observation, besoins.groupe (EB-AAMMJJ-HHMMSS-xxx) ; RPC besoin_creer(p_magasin, p_urgence, p_motif, p_lignes jsonb)
-- (une seule notification par demande) ; nt_besoin ignore les lignes groupées à l'insertion ; liste regroupée par demande
-- avec « Tout approuver / Tout refuser / Tout marquer servi ».

-- v94 (2026-11-25) : suivi des expressions de besoin pour le demandeur
-- besoins : vu_le/vu_par, qte_servie, rupture, achat_ref, delai_prevu, suivi_note, servi_le.
-- besoin_vu(ids) (appelé à l'ouverture de Magasins par direction / resp. ops / approvisionnement → « vue » notifiée une fois par demande),
-- besoin_suivi(id, servir|rupture|achat, qte, délai, réf. DA, note) → notifications au demandeur (partiel + reste + délai, rupture, DA).
-- Rupture : lier une demande d'achat existante ou la créer (préremplie) ; liste : avancement « x/y servis », états par article.

-- v95 (2026-11-25) : maquettes validées + besoins
-- Barre de dictée unique (« 🎤 Dicter » / « Arrêter · m:ss » / « Continuer la dictée », langue en pastille, mise au propre IA automatique,
--   liens « Revenir au texte dicté » et « Ré-améliorer », zones de texte auto-extensibles, objet « ✨ déduit par l'IA »).
-- Expressions de besoin : fiche détaillée ouvrable (clic sur la demande ou sur la notification), besoin_modifier (quantité, unité,
--   observation ; motif obligatoire si approuvé ; notification au demandeur ; trace modifie_nom/modifie_le/modif_note).

-- v96 (2026-11-26) : traitement des retards — un seul bouton « Traiter »
-- Choix : Présent (erreur d'appel) · Retard autorisé (heure + permission + motif) · Absent · Retard non justifié (heure).
-- statuts_jour : statut 'p' autorisé ; retard_traiter : present/justifie/retard → statut 'p' (plus de retenue « absence »),
-- absent → 'nj' ; présent clôt la suite (aucune mesure) ; heure obligatoire pour retard autorisé et non justifié.

-- v97 (2026-11-26) : navigation
-- Accueil : cartes « Tâches du shift / Tâches de vol / Missions assignées » (compteurs seuls) ; clic → page dédiée.
-- Cartes Vols, Zones, Signalements, Rapport Ops, Demandes d'achat : ouvrent une page (plus de dépliage dans l'accueil).
-- Historique de navigation (navGo/navBack + history.pushState) : bouton « ← Retour · page précédente » sur toute page ouverte
-- depuis une autre (cartes, liens internes, notifications) ; le bouton retour du téléphone revient aussi en arrière.

-- v98 (2026-11-26) : cartes d'effectif de l'accueil
-- Tant que la présence n'est pas renseignée (ni rapport de situation, ni appel fait, ni absence saisie) : « — / effectif »,
-- barre vide et « Présence pas encore renseignée » au lieu de « 31 / 31 (100 %) ». Badge rapport : « ⏳ Rapport en attente ».

-- v99 (2026-11-26) : encadré superviseurs — « ⏳ En attente » pour Manutention et Nettoyage tant que leur rapport n’est pas reçu.

-- v100 (2026-11-26) : cartes d’effectif — plus de source répétée après chaque nom (seuls les vrais motifs restent) ; une ligne discrète « Source : rapport Jotform hh:mm · appel de présence hh:mm ».

-- v101 (2026-11-26) : présence affichée telle que déclarée
-- Cartes d'effectif : présents / effectif repris du dernier rapport Jotform ou de l'appel (le plus récent), jamais recalculés
--   depuis l'annuaire ; chefs d'équipe = ceux du rapport ; « — / effectif prévu » tant que rien n'est déclaré.
-- sync_presences : le dernier rapport de chaque équipe (rapports_detail.groupe) pour un shift fait foi ; un agent cité absent dans
--   un rapport précédent mais plus dans le dernier repasse présent (statut 'p') ; numéros lus d'abord comme matricules, puis badges.

-- v102 (2026-11-26) : éléments de test et suppression
-- Colonne test sur signalements, discipline, incident_reports, taches ; case/choix « 🧪 Test » à la création (signalement,
-- demande d'explication, mise à pied, tâche ; la décision AVT/MAP hérite du test de la DE) ; badge « 🧪 TEST » dans les listes.
-- element_supprimer(type, id) : suppression définitive réservée à El Moustapha Ahmed Dedda (signalement + événements/PJ/corrections BDM,
--   rapport d'incident, document disciplinaire + décisions liées + jours de MAP, tâche). element_test(type, id, val).
-- SIG/2026/003 « Fiite deau » marqué test.

-- 2026-11-26 : paie_periode et recap_paie ignorent les jours de MAP d’un document marqué test ; la suppression d’une MAP (element_supprimer) efface ses jours « mp » → retirés de la paie.

-- v103 (2026-11-26) : performance de l'accueil
-- Client : bloc « Planning du jour » calculé en parallèle et sans données lourdes des vols ; apLoad en une vague et mutualisé (20 s) ;
--   loadAL/loadRA en parallèle ; accueil affiché immédiatement depuis la dernière version (localStorage vc_shift_<uid>) puis actualisé.
-- Serveur : index rapports_staff (jf_utc(brut)) partiel, (categorie, jf_utc(brut)), (form_id), (recu_le), partiels categorie null /
--   numeros_vol null ; marquer_taches_auto bornée dans le temps (3,1 s → 0,06 s, toutes les 5 min) ; situation_staff filtrée par date
--   (≈600 ms → quelques ms) ; lier_rapports_vols limitée aux 4 derniers jours.

-- v104 (2026-11-26) : Discipline en 3 cartes (DE, lettres d’avertissement, mises à pied) avec étapes en attente ; page par type (← Retour · Discipline, ＋ Nouvelle…, filtres En attente / Toutes) ; nouvelle lettre / MAP à partir d’une DE signée ou refusée (objet repris), MAP manuelle conservée.

-- v105 (2026-11-26) : formulaire « Nouvelle recrue / Modifier »
-- Site « Aéroport AINO (global) » : services Nettoyage, Manutention, Transport, Cuisine / restauration, Désinfection ;
-- ASECNA et sites de la ville : Nettoyage uniquement (équipe « <site> Nettoyage »). Affectation / sous-service et zone : nettoyage
-- aéroport uniquement. Rôles par service (agent / chef d'équipe / superviseur ; désinfection : agent / chef ; transport : chauffeur ;
-- cuisine : cuisinier / aide-cuisinier). Case « Sans badge ». Référence : agents.reference_nom, agents.reference_tel
-- (agent_ajouter / agent_modifier mis à jour).

-- v106 (2026-11-26) : expression de besoin — liste d’articles intégrée (visible sur téléphone, filtrée à la frappe, nouvel article possible) au lieu de la liste native ; unité libre (liste de choix + « Autre… »), seulement proposée par le catalogue tant que l’utilisateur ne l’a pas changée.

-- v107 (2026-11-26) : conditionnement lu par l'IA
-- Fonction ia-conditionnement (source docs/functions/ia-conditionnement) : emballage, facteur, unité de base, total, interprétation.
-- besoins.cond (jsonb) enregistré par besoin_creer ; repli local (12/carton, 4x12/colis, 50 kg / barrique, carton de 12…).
-- articles.conditionnement (proposé dans l'observation). Articles ajoutés : Javel en grains (kg, 50 kg / barrique),
-- Lave-sol Maxell (20 L) et Lave-mains Maxell (20 L) (litre, 20 L / bidon), Chaussures de sécurité (paire),
-- Protections auditives (bouchons d'oreilles) (paire) — EPI / tenues.

-- v108 (2026-11-26) : expressions de besoin servies consultables — filtres En cours / Servies-clôturées / Toutes (400 dernières lignes) ; fiche : état, vue, approbation, service, délais (demande→approbation, approbation→service, total) ; « Suivi détaillé » par article (qui, quand, rupture, partiel, remarques). besoins.servi_nom renseigné par besoin_decider / besoin_suivi.

-- v110 (2026-11-26) : carte « Appels d’offres (veille) » sur l’accueil (direction, resp. ops, coordinateur), ouvre la page veille.

-- v111 (2026-11-26) : veille multi-sites — beta.mr + TendersInfo (Mauritanie : tous, services, eau-assainissement) + GlobalTenders (Mauritanie) ; mots-clés FR/EN ; titre et résumé en français par l’IA ; source affichée. Sites testés non lisibles par le serveur : ARMP, marchespublics.gov.mr, CNCMP, dgMarket, TendersOnTime, Devex, UNGM, AMI, Cridem (bloqués, introuvables ou trop lents).

-- v112 (2026-11-26) : Magasins — accès complet pour responsable_comptabilite (Abderahmane) : tous les magasins, approbation / service / rupture / modification des besoins, bons de dotation (préparer, valider, expédier), quotas, mouvements. Fonctions besoin_* et dotation_* + politiques besoins (bs_r), mouvements_stock (mv_i), dotation_quotas (dq_w) mises à jour.

-- v113 (2026-11-26) : correctif — sw.js était resté à eps-ops-v108 (mises à jour v109–v112 non distribuées aux téléphones) ; « Appels d’offres » aussi dans le menu.

-- v114 (2026-11-26) : fiche d’expression de besoin — cases à cocher par article, « Servir » et « Rupture → demande d’achat » sur la sélection (ou sur tous les articles en attente si rien n’est coché) ; demande d’achat unique préremplie (objet, quantité, détail des articles), articles liés à sa référence. Comptabilité : plus de droit de modifier une demande (besoin_modifier).

-- v115 (2026-11-26) : modification des besoins — réservée à El Moustapha Ahmed Dedda, aux superviseurs principaux et au demandeur ; une modification faite par un autre est proposée (besoins.modif_attente) et appliquée seulement après validation par El Moustapha (besoin_modif_valider, notifications). Rupture / service partiel : date de disponibilité facultative, option « Date indéterminée ».

-- v116 (2026-11-26) : superviseurs principaux et superviseurs — magasins de l’aéroport uniquement (extérieur, intérieur, ASECNA) : fonction magasin_visible() dans les politiques magasins, mouvements_stock, bilans_magasin, dotations, magasin_seuils, seuil_alertes (stock_actuel suit, security_invoker) ; filtre aussi à l’écran. Veille AO : superviseur principal retiré de la politique veille_ao_sel (onglet déjà absent pour eux).

-- v117 (2026-11-26) : superviseurs principaux et superviseurs — RH limité à l’AINO : sélecteur de site réduit à « AINO (aéroport) », agents des autres sites retirés de leurs listes (annuaire, présence, discipline, anciens employés).

-- v118 (2026-11-26) : cloisonnement par site des équipes terrain (superviseurs principaux, superviseurs, chefs d’équipe) — profiles.site (vide = AINO), mon_site(), magasin_visible() par site (AINO = magasins aéroport + ASECNA ; autre site = son magasin) ; à l’écran : agents, magasins et RH de leur site uniquement ; équipes d’un autre site : onglets Tâches, Magasins, RH, Profil, Messages seulement.

-- v119 (2026-11-26) : droits terrain et complaintes Help Desk reçues
-- Chefs d'équipe : plus d'onglet Magasins ; bouton « 📦 Demander un approvisionnement » sur l'accueil (expression de besoin).
-- Superviseurs Manutention : articles limités à ceux de la manutention (articles.pour_manutention : chaussures de sécurité,
--   gants manutention, protections auditives, gilet haute visibilité, café petit déjeuner) — politiques ar_r et mv_r.
-- Complaintes BDM reçues par e-mail (rama@eps.mr) : table bdm_recus, fonction bdm-ingest (IA : n° BDM, objet, lieu, concerne EPS),
--   bdm_recu_tache() → tâche « 🎫 Complainte BDM » pour l'équipe nettoyage en service (échéance 1 h) + notifications ;
--   relais Gmail (Apps Script) à installer depuis Profil → « 📧 Relais Gmail » (relais_etat, relais_jeton réservé à El Moustapha).

-- v120 (2026-11-27) : annuaire — filtre « Avec badge / Sans badge » corrigé : les agents marqués « Sans Badge »
--   (119 agents) étaient comptés comme ayant un badge. Seul un vrai numéro compte désormais comme badge.

-- v121 (2026-11-27) : ♿ Situation des fauteuils roulants (une par shift)
-- Table fauteuils_situations (jour unique, nombres, réparations en quantités, problemes[], observation, message, historique des corrections),
-- fauteuils_lecteur()/fauteuils_saisisseur(), RPC fauteuils_enregistrer(p) (upsert + tâche du jour marquée « fait »),
-- modèle de tâche 'fauteuils' (Manutention M<garde>, 09:00 → 12:00). Page « ♿ Fauteuils roulants » (saisie + historique),
-- message WhatsApp sans les lignes à zéro ou vides ; note « numérotation des chaises planifiée ».

-- v122 (2026-11-27) : Signalements réorganisés
-- signalements : colonnes canal (helpdesk/interne, rétro-rempli), attente_motif/attente_le/attente_par ; RPC sig_maj (en cours / en attente avec motif /
-- clôturée — clôture permise aux chefs pour les complaintes de nettoyage), sig_probleme (« J'ai un problème » + notification équipe opération).
-- bdm_recu_tache : chaque complainte reçue par e-mail crée aussi un signalement Help Desk (bdm_recus.signalement_id) ; bdm-ingest v3 l'appelle toujours.
-- Edge function msg-helpdesk : message WhatsApp (constat + « Merci de nous lancer une complainte pour … » si nettoyage, sinon « Merci d'intervenir »),
-- sans signature, langue fr/en/ar. Page : cartes Tout / Help Desk (Nettoyage, Autres) / EPS interne, états À faire / En cours / En attente / Fait,
-- historique des BDM, regroupement par catégorie, accès au rapport d'incident.

-- v123 (2026-11-27) : grand ménage et rapport d'incident
-- Tâches de ménage (n_grand_menage, La Gardère, Duty Free, « ménage ») : « Démarrer » → zone, sous-zone, photos, option « Solliciter une complainte
--   Help Desk » (signalement canal helpdesk, catégorie Nettoyage, photos jointes, message WhatsApp) ; N° BDM + heures saisis ensuite dans la fiche.
-- Rapport d'incident : complainte ★ principale + complaintes liées (Breakdown history), suggestions automatiques de complaintes similaires et de
--   rapports précédents (registre + table ir_archives) ; bouton « Rapport d'incident » dans chaque fiche ; import des anciens rapports PDF/Word
--   (texte extrait dans le navigateur) réservé à El Moustapha (table ir_archives, indicateur retire).

-- v124 (2026-11-27) : rapport d'incident — libellé « IR No.: » ; seules les complaintes Help Desk (NKC-BDM-…) sont proposées ;
--   consigne à l'IA : rédaction en anglais, destinataire AFROPORT FM (Facility Management) ; import : référence = nom du fichier tel quel.

-- v125 (2026-11-27) : navigation — la page ouverte (et l'historique « Retour ») est mémorisée (localStorage navp, 6 h) :
--   après actualisation ou retour dans l'application, on revient sur la même page et à la même position.

-- v126 (2026-11-27) : accueil, appel, retards et absences non justifiées
-- Accueil : shift compacté (début → fin · équipes ; Équipe 4 08h-16h en/hors service), « 👥 Encadrement présent » (dernière action
--   « Je prends service ») + « 🕘 Historique » (prises_service par date), cartes d'effectifs juste après, carte appel déplacée sous les tâches
--   et compactée (appel appli / situation Jotform par équipe, matin et 17h).
-- Retards : 📞/💬 dans « Traiter » ; après Absent / Retard non justifié → décision (demande d'explication préremplie, convocation, sans suite) ;
--   retard_suite_donner : suites 'conv' et 'sans', ouvert aux RH.
-- Absences non justifiées : statuts_jour.cas_* (décision, clôture, DE liée, notification) ; RPC cas_absence_decider / cas_absence_clore ;
--   cron 'absences-cas-retour' (cas_absences_notifier, cas à partir du 27/11) : notification urgente au retour de l'agent si le cas est ouvert.

-- v127 (2026-11-27) : comptabilité — carburant
-- « Carburant » retiré des dépenses diverses ; fournisseurs.categorie / facturation / cycle_jour ; fournisseur « STAR (Station) »
--   (Carburant, facture mensuelle, cycle du 20 au 20). Table bons_carburant (photo du bon lue par l'IA via la fonction bon-carburant,
--   champs corrigés et cochés « vérifié » avant validation, n° de bon unique), bloc STAR par cycle, « Facture du cycle » (factures + facture_id),
--   flotte : carburant du mois repris des bons. Création de fournisseur : catégorie en liste déroulante avec « Autre ».

-- v128 (2026-11-27) : comptabilité — « 💰 Salaire et paie » regroupe Situation globale (filtres existants), Congés, Prêts et avances,
--   Primes et bonus (primes_mois.type : Agent du mois, Gratification, Bonus mission, Autre…).

-- v129 (2026-11-27) : accueil — un seul bouton « 📣 Signalement / Tâche » (ouvre la page Signalements, où se créent signalements,
--   complaintes et tâches ; approvisionnement pour les chefs sans magasin) ; « Demander un approvisionnement » retiré de l'accueil ;
--   « 📍 Arrivée / départ » : un bouton, puis choix « Je suis arrivé à l'aéroport » / « Je quitte l'aéroport » avec le dernier statut.

-- v130 (2026-11-27) : accueil — carte « Appel & situation du staff » réellement compacte (grille 3 colonnes, une ligne par équipe et par appel de 17h)
--   et correction de la détection des situations Jotform (comparaison de dates) ; « Rapport du shift Ops » et « Appels d'offres » retirés de l'accueil
--   (rapport via la tâche du shift, veille via son onglet).

-- v131 (2026-11-27) : accueil — les alertes « rapport de situation non reçu » (loadRA) sont recalculées à chaque affichage, au retour
--   dans l'application et toutes les 3 minutes (elles n'étaient calculées qu'au démarrage, d'où des « non reçu » déjà reçus).

-- v132 (2026-11-27) : message fauteuils roulants — plus de ligne « Observation » ; RAS / vide → rien ; sinon « NB: … » en fin de message.
--   Vérification synchro Jotform : situations reçues en base 0 à 14 min après l'envoi (25/11 → 27/11) ; les « non reçue » venaient de l'affichage (corrigé v130-v131).

-- v133 (2026-11-27) : accueil — bouton « Signalement / Tâche » sans icône et texte autorisé sur deux lignes (débordait sur téléphone).

-- v134 (2026-11-27) : relais Gmail — script pour archiveseps@gmail.com : complaintes reconnues aussi après transfert (BDM, complainte,
--   complaint, help desk, rama@eps.mr), libellé « eps-ops » posé seulement si l'envoi a réussi (code < 300), journal des envois (Logger).
--   Constat : aucun appel de Gmail vers msg-ingest / bdm-ingest depuis le 22/11 (seul le test du 26/11).

-- v135 (2026-11-27) : messages de vol — 2 pastilles par vol (PSM, LDM/CPM), vert reçu / rouge non reçu, cliquables : message prêt à partager
--   (PSM : résumé PMR ; LDM/CPM : interprété par l'IA, fonction ldm-ia). Notification à chaque PSM / LDM / CPM reçu (trigger nt_msg_vol →
--   chefs et superviseurs Manutention, superviseurs principaux, responsable et coordinateur des opérations).
