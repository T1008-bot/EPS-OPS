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
