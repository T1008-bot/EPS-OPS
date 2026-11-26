# Prompt — Module Ressources humaines d'EPS OPS

> À coller tel quel comme contexte pour une IA, un développeur ou un prestataire qui doit comprendre, utiliser, maintenir ou faire évoluer le module RH de l'application EPS OPS.

---

## 1. Contexte

Tu interviens sur **EPS OPS**, l'application de pilotage opérationnel d'**EPS.SARL** (EPS Prestation Services). EPS est prestataire de **nettoyage** et de **manutention bagages** à l'**aéroport international de Nouakchott-Oumtounsy (AINO)**, en Mauritanie. Elle intervient aussi sur des **sites en ville** : DGSN, ENAJM, CHN, MIF, ministère du Pétrole, UNPM, et ASECNA à l'aéroport.

L'application est utilisée **surtout sur téléphone**, en **français**, par la direction, l'équipe opération, les RH, la comptabilité, les superviseurs et les chefs d'équipe.

Le **module RH** regroupe tout ce qui concerne le personnel :
- qui travaille et où ;
- qui est présent ;
- qui est absent, en congé ou en mise à pied ;
- les dossiers individuels ;
- la discipline ;
- les évaluations ;
- les demandes des agents ;
- le lien avec la paie.

### Règles de travail permanentes
- Toujours répondre et rédiger **en français**.
- Vocabulaire : dire « **Manutention bagages** », jamais « bagage » ou « bagagiste » seul.
- **L'application fait foi.** Une liste extérieure (Excel, PDF, capture) peut être obsolète : un écart avec elle ne justifie pas de modifier une fiche sans accord.
- **Aucune déduction implicite.** Les chiffres de présence s'affichent tels que déclarés (appel ou rapport Jotform), sans recalcul à partir de l'annuaire.
- Toute **nouvelle mise en page** passe d'abord par une **maquette validée**.
- Éviter les suppressions en base. On préfère des indicateurs (`retire`, `annule`, `supprime_le`, `masque_listes`, `test`).
- **« Équipe opération »** = responsable des opérations, directeur des opérations, coordinateur des opérations, consultant RH et opérations, superviseurs principaux.

---

## 2. Architecture technique

| Couche | Technologie | Rôle |
|---|---|---|
| Interface | **Une seule page web** `index.html` (JavaScript sans framework), installable comme application (PWA) | Toutes les pages, fenêtres et formulaires |
| Cache hors ligne | `sw.js` (service worker, cache versionné `eps-ops-vN`) | Mise à jour de l'application à chaque version |
| Hébergement | **Vercel** (déploiement automatique depuis la branche `main` du dépôt GitHub) | Mise en ligne |
| Base de données | **Supabase / PostgreSQL** | Données, règles d'accès, calculs |
| Sécurité | **RLS** (règles par ligne) + fonction `mon_role()` + fonctions serveur `security definer` | Chaque rôle ne voit et ne modifie que ce qui le concerne |
| Fichiers | Supabase Storage (documents agents, signatures, PDF, pièces jointes) | Pièces d'identité, photos, documents signés |
| Tâches planifiées | `pg_cron` | Synchronisations, contrôles, rappels |
| Notifications | Table `notifications` + fonction `notifier(rôles, utilisateurs, catégorie, titre, texte, lien, réf.)` + envoi push sur téléphone | Alertes RH |
| IA | Fonction serveur `ia-texte` (dictée transcrite, texte consolidé, objet déduit, rédaction des demandes d'explication et des décisions) | Saisie facilitée |
| Formulaires terrain | **Jotform** (rapports « Situation du staff » des chefs d'équipe) | Source officielle de la présence par shift |
| Archives | **Google Drive** (classeurs du personnel, dossier PERSONNEL) | Consultation et mise à jour des classeurs |
| Progiciel | **ITGHANE** (« Progiciel EPS ») | Échange bidirectionnel : fiches, documents, signatures |

### Principes de l'interface
- **Navigation par cartes.** Chaque carte affiche des compteurs et des alertes. Touchée, elle **ouvre une page séparée** ; elle ne se déplie pas.
- **Bouton « ← Retour · page précédente »** sur toute page ouverte depuis une autre. Le bouton retour du téléphone fonctionne aussi.
- **Fiches en fenêtre** (fiche agent, formulaires) avec bouton ✕ / Fermer.
- **Dictée vocale** dans toutes les zones de texte :
  - un bouton unique « 🎤 Dicter » ;
  - à l'arrêt, l'IA met le texte au propre ;
  - « ↶ Revenir au texte dicté » permet d'annuler ;
  - l'objet est déduit automatiquement (étiquette « ✨ déduit par l'IA »).
- **Badges de statut** : orange pour « en attente », rouge pour « urgent / non conforme », vert pour « terminé ».
- **Élément de test** : badge « 🧪 TEST ». Suppression définitive réservée à un seul compte (responsable des opérations).

---

## 3. Rôles et accès au module RH

| Rôle (code) | Accès RH |
|---|---|
| `direction`, `responsable_ops`, `coordinateur_ops` | Tout : effectifs, présence, discipline, paie (comptabilité), décisions |
| `superviseur_principal` | Effectifs, présence, discipline, avis sur les demandes d'explication |
| `superviseur_nettoyage`, `superviseur_bagages` | Effectifs, présence, discipline de leur service |
| `chef_nettoyage`, `chef_bagages` | Présence de leur équipe (appel), demandes d'explication à remettre |
| `responsable_rh` (Anna Ndiay), `assistante_rh` (Mame Fatou) | Tâches, shift, **Effectifs & annuaire**, **Suivi présence**, **Discipline**, profil |
| `responsable_comptabilite` (Abderahmane) | Comptabilité (dont **situation de paie**), effectifs, présence, discipline |
| `approvisionnement` (Ndeye Diaty Ba, relations extérieures) | Effectifs, présence, discipline, comptabilité |

- **Menu.** Pour ces rôles, les trois pages RH (Suivi présence, Discipline, Effectifs & annuaire) sont regroupées sous **une seule entrée « 👥 Ressources humaines »**.
- **NNI** (numéro national d'identité) : visible et modifiable uniquement par les rôles autorisés.
- **Connexion.** Identifiant = numéro de téléphone (ou e-mail). Mot de passe initial = même numéro, changement imposé à la première connexion.

---

## 4. Structure du module (pages, volets, cartes)

### 4.1 Page d'accueil RH — « Ressources humaines »
**Barre de périmètre** (le choix est mémorisé sur le téléphone) :
- **Site** : AINO (aéroport) ou un site de la ville ;
- **Service** (à AINO) : Tous services · 🧹 Nettoyage · 🧳 Manutention.

**Trois cartes principales**, chacune avec ses compteurs et une bordure d'alerte s'il y a quelque chose à traiter :
1. **📊 Suivi présence** (shift du jour) : absences non justifiées · absences justifiées · congés · mises à pied · « congé(s) sans décision RH ».
2. **⚖️ Discipline** : à remettre à l'agent · avis attendu · mises à pied en cours · dossiers du mois.
3. **🗂 Effectifs & annuaire** : agents · encadrement · informations à compléter · départs à confirmer · demandes des agents en cours.

**Carte « 🧑‍✈️ Encadrement »** : un tableau avec deux bascules, **Superviseurs** et **Chefs d'équipe** (nom, matricule, fonction, équipe, téléphone).

**Carte « 📌 À traiter »** : la liste unique des actions RH en attente, chacune avec un lien vers la fiche :
- dossiers à compléter (nouvelles fiches de moins de 60 jours sans date d'embauche, téléphone ou NNI) ;
- congés sans décision ;
- absences non justifiées du shift ;
- demandes d'agents en cours ;
- demandes d'explication à remettre ;
- avis attendus ;
- départs à confirmer.

### 4.2 Effectifs & annuaire
- **En-tête** :
  - **🔎 Consulter (classeurs)** : ouvre les classeurs Google Drive du personnel ;
  - **🗄 Anciens employés** : archives des sortis, avec date et motif de départ ;
  - **✏️ Mettre à jour** : **ajouter une recrue** (matricule proposé automatiquement selon la plage du site), **enregistrer un départ** (départ définitif ou **transfert** vers une autre équipe ou un autre site) ou **modifier une fiche**.
- **Cartes d'information** : demandes des agents et informations à compléter.
- **Filtres** :
  - recherche par matricule, badge, téléphone ou nom ;
  - équipe, service (Nettoyage / Manutention), statut du jour.
- **Tableau** : matricule, badge (« Sans Badge » si aucun), nom, fonction, téléphone (lien d'appel et WhatsApp), statut du jour.
  - Un **⚠** signale un **numéro à vérifier**, un « ⚠ à renseigner » un numéro manquant.
  - Ces signalements créent automatiquement une **tâche RH**, qui se ferme quand le numéro est corrigé ou confirmé (« ✔ Numéro vérifié »).

### 4.3 Fiche agent (fenêtre)
**En-tête** :
- photo, nom, civilité, téléphone cliquable ;
- **Matricule · badge** ;
- **Date d'embauche** et ancienneté ;
- **Groupe / équipe** ;
- **Service** ;
- **Aujourd'hui** (statut du shift) ;
- **Suivi RH** (situation particulière suivie).

**Dossier de l'agent.** Chaque élément ouvre son détail :
- **📅 Assiduité** sur une période au choix : NJ, J, congés, MAP, retards ;
- **🌴 Permissions et demandes** :
  - permission de départ, permission de quelques jours, demande de prêt, anticipation de congé, justificatif d'absence, autre document ;
  - circuit de validation et suivi en cours / à venir ;
- **⚖️ Discipline** : dossiers de l'agent ;
- **⭐ Évaluation** : grilles d'évaluation ;
- **📁 Documents** : pièce d'identité, photo, casier judiciaire, badge. Une alerte « À compléter » s'affiche si une pièce manque ;
- **💰 Finance** : prêts / avances, primes du mois ;
- **🕓 Historique** : parcours de l'agent (embauche, transferts, changements) et événements datés.

**Actions** : « + Demande / justificatif / autre », modification de la fiche, enregistrement du départ.

### 4.4 Suivi présence
**Vue principale** :
- statuts des 30 derniers jours ;
- **rapports « Situation du staff »** reçus des chefs d'équipe (Jotform) ;
- **numéros inconnus** cités dans les rapports (matricules ou badges introuvables).

**🌴 Congés** :
- planifier un congé, suivre les congés en cours et à venir ;
- **congés sans décision RH** (agent déclaré en congé sans dates confirmées).

**📌 Situations à suivre** (absentéisme) :
- filtres : période (7 / 30 jours / personnalisée), seuil, service, équipe, état ;
- liste des agents qui dépassent le seuil, avec le suivi RH.

**Appel de présence dans l'application**, par équipe, par le chef d'équipe ou le superviseur :
- tout le monde est présent par défaut ; on coche les absents et les retards ;
- il compte les **chefs d'équipe et les agents** et enregistre la position GPS ;
- un appel du soir est aussi possible.

**Traitement des retards** — un seul bouton **« Traiter »**, quatre choix :
1. ✅ **Présent — erreur d'appel** : rien n'est compté ;
2. 🕘 **Retard autorisé (justifié)** : heure d'arrivée, qui a accordé la permission et motif obligatoires ; non compté ;
3. ❌ **Absent** : reste absence non justifiée ;
4. ⏱ **Retard non justifié** : heure d'arrivée obligatoire ; retard compté.

Ensuite, **suite à donner** : informer les RH, demande d'explication, avertissement verbal, autre. Les RH sont notifiées à chaque étape.

### 4.5 Discipline (3 cartes)
**Page Discipline** : trois cartes avec leur total et leurs **étapes en attente** :
- **📝 Demandes d'explication** ;
- **⚠️ Lettres d'avertissement** ;
- **⛔ Mises à pied**.

**Page de chaque type** (avec ← Retour · Discipline) :
- bouton **＋ Nouvelle …** ;
- filtres **En attente / Toutes** ;
- étape affichée sur chaque dossier.

**Demande d'explication** :
1. Dictée ou saisie des faits.
2. L'IA rédige : agent, civilité, date, poste d'affectation, **objet** au format « Nature du manquement – Poste, shift du JJ/MM/AAAA au JJ/MM/AAAA » et faits enrichis.
3. Signature de l'émetteur.
4. Remise à l'agent, faite par l'émetteur ou déléguée : lecture, réponse, signature de l'agent, ou refus constaté par un témoin.
5. Avis de l'émetteur.
6. Décision.

**Étapes possibles** :
- à remettre à l'agent ;
- avis de l'émetteur attendu ;
- décision attendue (transmis) ;
- décision prise ;
- classée sans suite.

**Lettre d'avertissement / mise à pied** :
- créée **à partir d'une demande d'explication** signée ou refusée ;
- l'**objet est repris à l'identique** ;
- la mise à pied peut aussi être saisie manuellement ;
- pour une mise à pied, durée et dates sont contrôlées (cohérence durée / début / fin / reprise) et les jours sont inscrits automatiquement en « Mise à pied » dans la présence, donc dans la paie.

**Documents** :
- PDF au modèle EPS (références `EPS/OPS/DISC/DE|AVT|MAP-<matricule>/<année>`) ;
- signatures, identifiant numérique du document signé ;
- partage.

**Agents à ne pas laisser prendre service** (convocation) : carte d'alerte avec « S'est présenté(e) » et « Lever l'interdiction ».

### 4.6 Évaluations
- **Évaluation de l'encadrement** (chefs d'équipe et superviseurs) : « Grille d'évaluation individuelle KPI du personnel d'encadrement ».
  - Note sur 100 avec appréciation : Excellent ≥ 95, Très bon ≥ 90, Bon ≥ 80, Acceptable ≥ 70.
  - Statuts : à évaluer, brouillon, soumise, partagée.
  - Avis de la hiérarchie.
- **Évaluations des agents** dans la fiche, rubrique ⭐ Évaluation.

### 4.7 Lien avec la paie (module Comptabilité)
- La **situation de paie** (période du 26 au 25) est calculée à partir des statuts de présence.
- **Retenue = salaire / 30 par jour** d'absence non justifiée ou de mise à pied.
- Les absences justifiées et les retards autorisés ne sont pas retenus.
- Les arrivées et départs en cours de période sont calculés au prorata.
- **Grille de salaire de base** selon les notes de service n° 0016 et 0017 (ancien / nouvel agent, chef d'équipe), et **période d'essai** :
  - le nouveau tarif s'applique après la fin du mois d'échéance de l'essai ;
  - la confirmation est validée par la comptabilité.
- Les jours de mise à pied d'un document **supprimé** ou **marqué test** ne sont pas retenus.
- Les **anciens porteurs masqués** (`masque_listes`) sont exclus des listes de paie.

---

## 5. Données (tables principales)

| Table | Contenu |
|---|---|
| `agents` | Fiche officielle : `matricule` (clé), badge, nom, civilité, équipe, service, site, fonction, zone, téléphone, date d'embauche, naissance, contact d'urgence, `actif`, date et motif de départ, `depart_a_confirmer`, `interdit_service`, `tel_a_verifier`, `masque_listes` |
| `agents_nni` | NNI (accès restreint) |
| `profiles` | Comptes utilisateurs : rôle, poste, matricule, téléphone, e-mail |
| `personnel_admin` | Personnel administratif |
| `statuts_jour` | Statut par agent et par jour de shift : `nj`, `j`, `c`, `mp`, `p` ; justification, champs de retard |
| `appels` | Appels de présence par équipe et par jour (présents / effectif, lignes, renforts, GPS, appel du soir) |
| `rapports_staff` → vues `situation_staff`, `rapports_detail` | Rapports Jotform bruts et lus (groupe, présents / effectif, renforts, chefs, superviseurs) |
| `conges` | Congés planifiés |
| `demandes_agent` | Demandes des agents (permissions, prêts, justificatifs…) et leur circuit |
| `suivi_absences` | Situations d'absentéisme suivies par les RH |
| `discipline` | Demandes d'explication, avertissements, mises à pied : étapes, avis, décisions, signatures, PDF, `test` |
| `interdits_suivi` | Suivi des interdictions de prise de service |
| `evaluations`, `evaluations_agents`, `eval_enc` | Évaluations |
| `documents_agent` | Pièces du dossier (stockées dans Storage) |
| `parcours_agent` | Historique : embauche, transferts, départs |
| `confirmations_essai` | Fin de période d'essai et confirmation |
| `prets_avances`, `primes_mois` | Éléments financiers |
| `horaires_individuels` | Horaires particuliers |
| `config_alertes` | Effectifs prévus par équipe (nettoyage 31, nettoyage N4 34, manutention 28), situation de recrutement, activation de l'appel |
| `import_classeurs` | Import des classeurs du personnel |
| `taches` | Tâches RH automatiques : `dossier:<matricule>`, `essai:<matricule>`, `tel:<matricule>`… |

---

## 6. Automatismes (côté serveur)

- **Synchronisation de la présence** (`sync_presences`, toutes les 15 min) :
  - lit les rapports Jotform des 36 dernières heures ;
  - **le dernier rapport de chaque équipe pour un shift fait foi** : un agent cité dans un rapport précédent mais plus dans le dernier repasse présent ;
  - les numéros sont lus **d'abord comme matricules**, puis comme badges.
- **Dossier incomplet** : à la création d'une fiche, une tâche RH « Dossier à compléter » (date d'embauche, téléphone, NNI) est créée. Elle se ferme automatiquement quand la fiche est complète.
- **Période d'essai** : une tâche est créée pour la comptabilité à l'échéance ; elle se ferme à la confirmation.
- **Numéro à vérifier** : tâche RH, fermée à la correction ou confirmation.
- **Listes Jotform** (équipes, matricules) synchronisées depuis `agents` à chaque modification, plus une passe quotidienne.
- **ITGHANE** : chaque modification des tables est transmise. En retour, les profils, documents et signatures saisis dans ITGHANE sont reçus.
- **Notifications** aux RH, à la comptabilité ou à l'équipe opération selon l'événement : retard traité, absence, décision disciplinaire, congé, numéro BDM, etc.
- **Matricules** :
  - aéroport : `11xx` encadrement, `12xx–13xx` nettoyage, `14xx` manutention ;
  - ville : DGSN 1601–1650, ENAJM 1651–1680, MIF 1681–1690, Pétrole 1691–1700 ;
  - proposés par `agent_matricule_suivant(service)` ;
  - un matricule réattribué garde l'ancien porteur avec le suffixe **D** (ex. `1250D`).

---

## 7. Ce que tu dois respecter si tu modifies le module

1. Afficher les chiffres **tels que déclarés** ; ne jamais recalculer un effectif à partir de l'annuaire.
2. Toute carte ouvre une **page séparée** avec **← Retour**.
3. Proposer une **maquette** avant tout changement visuel.
4. Garder la **traçabilité** : qui, quand, pourquoi, pour toute modification sensible (ancien / nouveau, motif).
5. Les autorisations se contrôlent **côté serveur** (RLS / fonctions), pas seulement en masquant un bouton.
6. Tester sur téléphone (≈ 400 px de large) et vérifier la vitesse : chargements en parallèle, index sur les dates.
7. Déploiement :
   - vérifier la syntaxe ;
   - incrémenter `eps-ops-vN` dans `sw.js` ;
   - noter le changement dans `docs/sql/appel_presence_essai.sql` ;
   - pousser la branche puis `main`.
