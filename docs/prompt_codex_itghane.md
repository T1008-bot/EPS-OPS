# Mission Codex — Aligner ITGHANE (Progiciel EPS) sur le modèle EPS OPS

> À coller tel quel comme consigne pour Codex, qui travaille sur le dépôt et la base d'**ITGHANE** (« Progiciel EPS »).
> État de référence : **EPS OPS v132 du 27/11/2026**.
> **Langue** : toujours répondre, commenter et rédiger en français.

---

## 0. Ce que tu dois faire

EPS OPS est l'application de pilotage opérationnel d'EPS. Ses écrans ont été affinés pendant des semaines avec ses utilisateurs (direction, opérations, RH, comptabilité, superviseurs, chefs d'équipe). Ergonomie, présentation et façon de travailler sont désormais validées. **ITGHANE doit suivre exactement le même modèle.**

**Cette première demande porte sur une mise à jour complète du contenu d'ITGHANE**, conformément à EPS OPS : tous les onglets, toutes les données, tous les circuits (personnel, présence, discipline, magasins, comptabilité, signalements et Help Desk, rapports d'incident, tâches, fauteuils roulants, carburant). Étapes :

1. **Inventaire** des onglets, écrans et tables d'ITGHANE.
2. **Tableau de correspondance** avec les onglets d'EPS OPS (§ 5). Pour chaque onglet, une colonne d'état :
   - ✅ conforme ;
   - 🔄 à mettre à jour (écarts listés) ;
   - ➕ à créer (n'existe pas dans ITGHANE) ;
   - 🟣 propre à ITGHANE (à conserver).
3. **Import et rapprochement complets des données** depuis EPS OPS, qui fait foi (§ 2 et § 6). Tous les jeux de données listés au § 6.3 sont **disponibles dès maintenant**.
4. **Maquettes** pour tout changement de mise en page, à faire valider avant de coder (§ 1).
5. **Mise à jour de tous les onglets**, lot par lot, jusqu'à ce que tout soit ✅ ou 🟣. Après chaque lot, un compte rendu : ce qui a changé, ce qui reste, les écarts de données constatés.

**Ne rien inventer.** Si une règle n'est pas écrite ici ou n'apparaît pas dans les données d'EPS OPS, pose la question au lieu de deviner.

---

## 1. Règles permanentes (identiques à EPS OPS)

- **Français partout**, dans l'interface comme dans les messages.
- **Vocabulaire** : écrire « **Manutention bagages** », jamais « bagage » ni « bagagiste » seul.
- **L'application fait foi.** Une liste extérieure (Excel, PDF, capture) peut être obsolète. Un écart ne justifie pas de modifier une fiche sans accord.
- **Aucune déduction implicite.** Les chiffres de présence s'affichent **tels que déclarés** (appel de l'application ou rapport Jotform). On ne les recalcule jamais depuis l'annuaire. Tant que rien n'est déclaré, on affiche « — / N » et « En attente ».
- **Maquette validée avant tout changement de mise en page.**
- **Pas de suppression en base** : pas de `DROP`, de `DELETE` ni de cascade. On utilise des indicateurs : `actif`, `retire`, `annule`, `supprime_le`, `masque_listes`, `test`. Une ligne annulée reste visible, barrée, et ne compte plus.
- **Montant du renfort** (500 MRU par shift) : il n'est **jamais affiché aux chefs d'équipe**.
- **Comptes** : identifiant = n° de téléphone (`<tel>@eps-ops.mr`). Mot de passe initial = ce même numéro, avec changement forcé à la 1re connexion. Si on corrige le numéro d'une personne qui ne s'est jamais connectée, on met à jour l'identifiant **et** le mot de passe initial.
- **« Équipe opération »** désigne :
  - le responsable des opérations ;
  - le directeur des opérations (rôle `direction`, poste « Directeur des opérations ») ;
  - le coordinateur des opérations, y compris le consultant RH et opérations ;
  - les superviseurs principaux.

  Côté base, c'est la fonction `equipe_ops()`.
- **Aucun secret dans le code ni dans le dépôt** (clés, jetons) : ils vont dans les secrets du serveur.

---

## 2. Source de vérité et échanges entre les deux applications

### 2.1 Qui fait foi

| Domaine | Fait foi | Commentaire |
|---|---|---|
| Personnel (matricule, nom, équipe, service, fonction, site, téléphone, badge, embauche, départ) | **EPS OPS** | Identifiant unique = **matricule**. Jamais de doublon. Badge « Sans Badge » = pas de badge. |
| Présence, appels, retards, absences, congés, mises à pied | **EPS OPS** | Source primaire = rapports Jotform « Situation du staff » et appels faits dans l'application. |
| Discipline (demandes d'explication, avertissements, MAP) | **EPS OPS** | Avec PDF et signatures. |
| Magasins, articles, mouvements, besoins, demandes d'achat | **EPS OPS** | |
| Comptabilité (paie, prêts, primes, fournisseurs, factures, dépenses, carburant) | **EPS OPS** | |
| Signalements, Help Desk, rapports d'incident | **EPS OPS** | |
| Comptes, documents et signatures saisis dans ITGHANE | **ITGHANE** | Transmis à EPS OPS par la fonction `itghane-entrant` (table `itghane_entrees`). |

### 2.2 Canaux existants (déjà en place)

- **EPS OPS → ITGHANE, en lecture** : fonction serveur `itghane` du projet Supabase d'EPS OPS. Appel **serveur à serveur uniquement**, avec la clé dédiée dans l'en-tête `x-eps-cle`. Chaque accès est tracé dans `api_journal`.
  - `jeu=catalogue` : liste des jeux de données avec leur description et leurs paramètres (`depuis`, `jusqu`, `limite`, `decalage`, ou `annee` / `mois` pour la paie).
  - `jeu=structure` : les colonnes de chaque jeu.
  - `jeu=changements&depuis_id=N` : flux des modifications (table `flux_ops`) pour rattraper ce qui a changé depuis le dernier identifiant lu.
  - `jeu=<nom>` : les données. Les pièces jointes arrivent avec des liens temporaires d'une heure (`lien_*`).
- **EPS OPS → ITGHANE, en temps réel** : envoi immédiat et signé de chaque changement vers l'adresse de réception d'ITGHANE (`app_secrets.itghane_webhook_url`).
- **ITGHANE → EPS OPS** : fonction `itghane-entrant` (comptes, documents, signatures). Côté ITGHANE : `pg_net` et `eps_ops_envoyer`.

**À faire** :
- Utiliser `catalogue`, `structure` et `changements` pour **aligner les tables d'ITGHANE**.
- Lister dans ton compte rendu les tables d'EPS OPS **absentes du catalogue** dont ITGHANE a besoin (voir § 6.3). Elles y seront ajoutées sur demande.

---

## 3. Organisation et repères métier

- **Activité** : EPS (EPS.SARL) assure le **nettoyage** et la **manutention bagages** à l'**aéroport international de Nouakchott-Oumtounsy (AINO)**. Elle intervient aussi sur des sites en ville : DGSN / Sûreté nationale, ENAJM, CHN, MIF, ministère du Pétrole, UNPM, ainsi qu'ASECNA à l'aéroport.
- **Sites** (`sites`, `profiles.site`, fonction `mon_site()`) :
  - les équipes AINO voient AINO : `aino_nett`, `aino_manut` et `asecna` ;
  - les équipes des autres sites ne voient que leur site, avec un accès réduit à Tâches, Magasin, RH, Effectifs, Présence, Discipline, Profil et Messages.
- **Équipes** :
  - **Nettoyage** : N1, N2, N3 (« Équipe 1/2/3 », shifts de 24 h de 08h à 08h) et N4 (« Équipe 4 », de 08h à 16h, hors service ensuite) ;
  - **Manutention bagages** : M1, M2, M3 (« Manutention 1/2/3 ») et « Manutention (rotatif) » ;
  - **Chauffeurs**.
- **Garde** : rotation 1 → 2 → 3, une équipe par jour. Le jour de shift change à 08h (fonction `garde_du(jour)`). Avant 08h, on est encore sur le shift de la veille.
- **Paie** :
  - période du **26 au 25** ;
  - salaires de base selon les **notes de service n° 0016 et 0017** ;
  - période d'essai de 3 mois, confirmée par la comptabilité ;
  - **renfort : 500 MRU par shift** ;
  - **retenue : 500 MRU par jour d'absence non justifiée ou de mise à pied**, un même jour n'étant retenu qu'une fois ;
  - prorata (salaire ÷ 30 × jours) en cas d'arrivée ou de départ en cours de période.
- **Statuts de présence** (`statuts_jour.statut`) :
  - `nj` = absence non justifiée ;
  - `j` = absence justifiée ;
  - `c` = congé ;
  - `mp` = mise à pied ;
  - `p` = présent (correction).

  Les retards sont suivis dans les colonnes `retard_*` : heure, issue, suite donnée, demande d'explication liée. Les cas d'absence non justifiée sont suivis dans les colonnes `cas_*` : décision, clôture, demande d'explication liée, notification.

---

## 4. Principes d'ergonomie à reproduire

1. **Mobile d'abord.** L'application est utilisée à 90 % sur téléphone. Les écrans sont compacts, les lignes courtes, il n'y a jamais de défilement horizontal de la page.
2. **Cartes → pages.** Une carte d'accueil **ouvre une page séparée** ; elle ne se déplie pas. Toute page ouverte depuis une autre a un bouton **« ← Retour · nom de la page précédente »**, et le bouton retour du téléphone fonctionne.
3. **Mémoire de navigation.** Après une actualisation ou une sortie de moins de 6 h, l'application rouvre **la même page à la même position**.
4. **Fiches et formulaires en fenêtre** (bas d'écran sur mobile), avec ✕ / Fermer.
5. **Badges de statut homogènes** :
   - orange : à faire, en attente ;
   - rouge : urgent, en retard, non fait, non reçu ;
   - bleu : en cours ;
   - vert : fait, reçu, clôturé.
6. **Filtres en boutons** (puces) avec compteurs, plutôt que des listes déroulantes cachées. Le filtre par défaut est « Tout ».
7. **Dictée vocale et IA** dans les zones de texte :
   - un bouton unique « 🎤 Dicter » ;
   - l'IA met le texte au propre ;
   - « ↶ Revenir au texte dicté » permet d'annuler ;
   - l'objet est déduit automatiquement (« ✨ déduit par l'IA »).
8. **L'IA propose, l'humain valide.** Exemples : photo d'un bon d'achat lue par l'IA, corrigée et cochée « vérifié » avant validation ; message WhatsApp rédigé par l'IA et modifiable.
9. **Messages WhatsApp prêts à l'envoi** :
   - bouton WhatsApp (`wa.me/?text=`) et bouton Copier ;
   - partage avec les photos via le partage du téléphone quand il y en a ;
   - l'expéditeur choisit lui-même le numéro ou le groupe ;
   - les lignes vides ou à zéro n'apparaissent jamais dans le message.
10. **Contacter avant de décider** : boutons 📞 Appeler et 💬 WhatsApp à côté de chaque décision concernant un agent (retard, absence).
11. **Notifications** :
    - table `notifications` et fonction `notifier(rôles[], utilisateurs[], catégorie, titre, texte, lien, réf., sauf)` ;
    - envoi sur téléphone (push) ;
    - le préfixe 🔴 Urgent est réservé aux cas qui exigent une action immédiate.
12. **Actualisation automatique** des écrans de suivi (accueil) : à chaque affichage, au retour dans l'application et toutes les 3 minutes, sauf si une saisie est en cours.
13. **Mode test** : une case « test » sur les créations. Les éléments test sont exclus des calculs (paie notamment).
14. **Traçabilité** :
    - journal d'audit (`audit_journal`, empreintes chaînées) ;
    - historique des corrections, par exemple du N° BDM (`sig_bdm_corrections`), visible uniquement par l'équipe opération et l'auteur ;
    - historique des versions (rapports d'incident, situations des fauteuils).

---

## 5. Onglets d'EPS OPS à reproduire (référence fonctionnelle)

Pour chaque onglet : son contenu, ses règles et qui y a accès. Les noms de tables sont ceux du projet Supabase d'EPS OPS.

### 5.1 Accueil « Shift actuel » / « Mon shift »
- **Carte personnelle** :
  - nom et poste ;
  - état de service : en service, service terminé, non pris, avec heure et position ;
  - deux boutons seulement :
    - **📣 Signalement / Tâche**, qui ouvre la page Signalements ;
    - **📍 Arrivée / départ**, qui ouvre un choix « 🛬 Je suis arrivé à l'aéroport » / « 🛫 Je quitte l'aéroport » (et « shift supplémentaire » si besoin). Position GPS relevée au moment du choix (`prises_service`).
- **Carte du shift (compacte)** :
  - sélecteur de date et bandeau des jours avec l'équipe de garde ;
  - ligne 1 : « 27/11 08h00 → 28/11 08h00 · N3 + M3 » ;
  - ligne 2 : « 27/11 08h → 16h · Équipe 4 », avec un badge en service ou hors service ;
  - superviseur principal, puis superviseurs et chefs d'équipe par service (d'après le rapport Jotform).
- **👥 Encadrement présent** :
  - seules les personnes dont la **dernière action est « Je prends service »**, avec leur heure et leur position ;
  - bouton **🕘 Historique** : qui est arrivé, qui est parti et à quelle heure, pour n'importe quelle date.
- **Cartes d'effectifs par équipe** (N3, N4, M3…) :
  - présents / effectif tel que déclaré, et pourcentage ;
  - absents par catégorie, avec les noms ;
  - écart avec l'effectif prévu (besoin de recrutement) ;
  - ligne discrète « Source : rapport Jotform 10h29 / appel 10h56 » ;
  - **le nom d'un absent non justifié ouvre son « cas »** (§ 5.6).
- **Alertes de rapports** : « Rapport de situation non reçu », avec bouton 🔔 Relancer le chef d'équipe (rappels à 10h et à 17h30).
- **Retards** : à confirmer, puis suite à donner, puis demande d'explication à établir (§ 5.6).
- **Vols** (carte qui ouvre la page Vols), puis interdictions de service, puis **Tâches du shift**.
- **📋 Appel & situation du staff** (sous les tâches), présentée en grille compacte :

  | Équipe | Appel (appli) | Situation (Jotform) |
  |---|---|---|
  | N3 | fait 10h56 / non fait | faite 10h43 / non reçue |
  | ↳ 17h | … | … |

  Une situation Jotform faite suffit, mais un appel non fait reste signalé.
- **Alertes en cours** (anticipation des vols et des effectifs).
- **Ne figurent pas sur l'accueil** : Appels d'offres (onglet propre) et Rapport du shift Ops (ouvert depuis la tâche correspondante).

### 5.2 Messages
Conversations internes, groupes et messages des vols (PSM, LDM, CPM reçus par e-mail via le relais Gmail).

### 5.3 Alertes
- Anticipation des vols et des effectifs, avec prise en charge et clôture ; niveaux veille et prioritaire.
- Alertes de vols toutes les 15 minutes.

### 5.4 Vols
- Programme, vols en direct (Flightradar), affectation (tapis, poste, passerelle, comptoirs).
- Messages du vol, checklists, rapports Flight Ops, PMR, cabine et cargo.

### 5.5 Effectifs & annuaire
- Recherche par matricule, badge, téléphone ou nom.
- Filtres : équipe, service (Nettoyage, Manutention, détail), présence, **badge (avec ou sans ; « Sans Badge » compte comme sans badge)**.
- **Fiche agent** : identité, NNI (réservé aux RH), embauche, badge, téléphone, contact d'urgence, personne de référence, documents (pièce d'identité avec expiration, photo, casier, contrats), parcours, demandes, absences des 30 derniers jours, discipline, prêts en cours.
- **Ajouter une recrue** :
  - services proposés selon le site, rôles proposés selon le service ;
  - case « Sans badge » ;
  - référence (nom et téléphone).
- **Départ** : nature, transfert, date, mise à jour du classeur Drive. Les anciens employés restent consultables.
- **Informations à compléter** : NNI, date d'embauche, téléphone, badge, badge ou téléphone partagé.

### 5.6 Suivi présence (et RH)
- **Appel dans l'application** (à 08h et à 17h) :
  - tout le monde est présent par défaut ; on note les absents et les retards ;
  - renforts avec heure d'arrivée confirmée ;
  - la situation officielle reste celle de Jotform.
- **Retards**, bouton « Traiter » avec 📞 et 💬 :
  - Présent (erreur d'appel) ;
  - Retard autorisé ;
  - Absent ;
  - Retard non justifié.

  Après « Absent » ou « Retard non justifié », un **écran de décision** s'ouvre :
  - demande d'explication générée automatiquement (objet et date connus) au nom de la personne RH qui traite ;
  - convocation au bureau (date et heure ; chef et superviseur du service notifiés) ;
  - sans suite (motif obligatoire).

  Les RH sont notifiées à chaque étape.
- **Cas d'absence non justifiée** :
  - contact 📞 / 💬 ;
  - shifts concernés à cocher (un ou plusieurs) ;
  - compte rendu à choisir : demande d'explication, avertissement verbal, avertissement écrit, mise à pied, arrêt, licenciement, convocation, sans suite.

  Suite selon la décision :
  - une demande d'explication, un avertissement écrit, une mise à pied, un arrêt ou un licenciement ouvrent la **demande d'explication préremplie** ; le cas reste ouvert jusqu'à « Clôturer le cas » ;
  - un avertissement verbal ou un « sans suite » clôturent immédiatement.

  **Au retour de l'agent** à un shift suivant, si son cas est encore ouvert : notification 🔴 urgente aux chefs et superviseurs **de son service**, aux superviseurs principaux et aux RH. Vérification toutes les 15 minutes (fonction `cas_absences_notifier`).
- **Congés** : planification, anticipation, reprise anticipée, prolongation.
- **Périodes d'essai** : fin d'essai, confirmation par la comptabilité.
- **Évaluations mensuelles** :
  - agents : 80 % présence, 20 % ponctualité, −10 points par dossier disciplinaire ;
  - encadrement : revue par le superviseur principal, validation par le responsable des opérations, transmission aux RH.

### 5.7 Discipline
Trois cartes (sections), puis étapes de la procédure :
- demande d'explication rédigée avec l'IA ;
- signatures de l'établissant, de l'agent, du témoin et de l'avis ;
- décision ;
- PDF signé ;
- délégation possible.

Accès : RH, équipe opération, superviseurs selon leur service.

### 5.8 Magasins
- Magasin central et magasins de l'aéroport (nettoyage, manutention, ASECNA), plus un magasin par site.
- **Visibilité par site** (`magasin_visible()`).
- **Superviseurs Manutention bagages** : uniquement les articles `pour_manutention` (chaussures de sécurité, gants, protections auditives, gilet haute visibilité, café du petit déjeuner).
- **Chefs d'équipe** : pas de magasin. Ils signalent un manque par « 📦 Demander un approvisionnement » depuis la page Signalements.
- **Expression de besoin** :
  - plusieurs articles par demande ;
  - unité libre ou « Autre… » ;
  - conditionnement lu par l'IA ;
  - date souhaitée ou « indéterminée » ;
  - suivi du demandeur : vu, servi partiellement, rupture, achat.
- **Modification d'une demande** : seulement le responsable des opérations (El Moustapha), les superviseurs principaux et le demandeur. Une modification faite par quelqu'un d'autre que le responsable des opérations attend son approbation.
- **Servir / Rupture** par cases à cocher, avec demande d'achat groupée.
- Dotations et quotas, mouvements, seuils d'alerte, bilan hebdomadaire (tâche du vendredi), consommations.

### 5.9 Tâches & planning
- **Tâches régulières générées chaque jour** depuis `taches_modeles`, pour l'équipe de garde (Nettoyage N…, Manutention M…). Échéance au shift ; minuteurs de 30 minutes après la prise de service.
- **« Démarrer » ouvre l'étape qui clôt la tâche** :
  - appel ;
  - situation Jotform préremplie ;
  - rapport du shift Ops (Manutention) ou rapport de shift Nettoyage ;
  - dispatching.

  Les superviseurs principaux voient les deux services.
- **Grand ménage** (et Duty Free, La Gardère…) : « Démarrer » demande zone, sous-zone et photos, avec l'option **« Solliciter une complainte Help Desk »** (message WhatsApp, puis N° BDM et heures saisis ensuite).
- **♿ Situation des fauteuils roulants**, une par shift (chefs et superviseurs Manutention, superviseurs principaux) :
  - formulaire prérempli avec le shift précédent ;
  - nombres réglés par − et + ; hors service calculé (total − en service) ;
  - cabine en service et hors service ;
  - réparations **en nombres** : envoyées aujourd'hui, en cours (reportées d'un jour à l'autre), retours du jour ;
  - pénuries et problèmes ;
  - note « 📌 Numérotation des chaises planifiée » en haut de page.

  Le message WhatsApp :
  - a pour titre « Situation des fauteuils roulants », puis « Shift du JJ/MM/AAAA » ;
  - omet toute ligne à 0 ou vide ;
  - n'a pas de ligne « Observation » : si elle vaut RAS, rien n'est ajouté ; sinon, « NB: … » en fin de message.

  L'historique est consultable à toute date (situations, réparations, problèmes).
- **Tâches et missions ponctuelles** : création, assignation, notes (info, question, justification, empêchement), photos, clôture avec position.

### 5.10 Signalements / Help Desk
- **En haut** :
  - trois cartes : **📋 Tout** (par défaut), **🎫 Help Desk** (sous-filtres 🧹 Nettoyage / 🛠 Autres), **🏢 EPS (interne)** ;
  - boutons **➕ Nouvelle complainte** (Help Desk), **➕ Nouveau signalement** (interne), ➕ Tâche / mission, ✅ Voir les tâches.
- **Quatre états** : **À faire / En cours / En attente / Fait**.
  - « En attente » = mis en pause pour un empêchement ou une contrainte ; le motif est obligatoire.
  - Les statuts détaillés restent consultables : brouillon, envoyé, réponse, BDM attribué, en cours, intervention terminée, vérifié, clôturé.
- **Canal** (`signalements.canal`) : `helpdesk` ou `interne`.
- **Fiche** :
  - **Mettre à jour** : en cours, en attente avec motif, clôturée (les chefs peuvent clôturer les complaintes de nettoyage), avec saisie du N° BDM et de son heure de réception ;
  - **⚠️ J'ai un problème** : pas de connexion, accès refusé, manque de produit, manque de personnel, zone occupée, autre. L'équipe opération est notifiée ;
  - chronologie, délais (constat → envoi → réponse → BDM → intervention → clôture), photos.
- **Message WhatsApp au Help Desk**, rédigé par l'IA (fonction `msg-helpdesk`) :
  - format : « 📍 lieu », puis le constat direct, puis la demande ;
  - nettoyage → « Merci de nous lancer une complainte pour … ». C'est EPS qui intervient, mais sur complainte du Help Desk ;
  - autre → « Merci d'intervenir » ;
  - sans signature ni nom d'équipe ;
  - langue française par défaut, anglais ou arabe au choix.

  L'heure d'envoi est confirmée et enregistrée.
- **Complaintes reçues par e-mail** (rama@eps.mr et les adresses des PDA, via le relais Gmail) :
  - fonction `bdm-ingest` (IA) ;
  - table `bdm_recus` ;
  - création d'un signalement Help Desk et, si EPS est concernée, d'une tâche urgente à faire dans l'heure pour l'équipe Nettoyage de garde, avec notifications.
- **Format BDM** : `NKC-BDM-xxxx`. La correction d'un N° BDM est tracée (motif obligatoire).
- **En bas de page** : 🗂 Historique des BDM, 🧩 Regrouper par catégorie, 📄 Rapport d'incident.

### 5.11 Rapports d'incident (destinés à AFROPORT FM — Facility Management)
- **Rédaction en anglais.**
- Libellé **« IR No.: »**. Numéro attribué à l'approbation (préfixe `EPS_AFRO_NKC_INC`, remise à zéro mensuelle). Un numéro attribué n'est jamais réutilisé.
- Uniquement des **complaintes Help Desk** (NKC-BDM-…) :
  - une **complainte ★ principale**, qui donne la description ;
  - les autres listées dans « C: Breakdown / Incident History ».
- **Avant rédaction**, suggestions automatiques :
  - complaintes similaires ;
  - rapports précédents liés, du registre et des anciens rapports importés (`ir_archives`, référence = nom du fichier tel quel).
- Sections A à G ; circuit préparation → vérification → approbation → émission ; versions ; export Word et PDF.

### 5.12 Zones & dispatching
Zones, lieux, postes, dispatching du nettoyage, signalements de zone, toilettes.

### 5.13 Technique
Matériel, inspections planifiées, interventions, signalements techniques, historique des équipements.

### 5.14 Demandes d'achat
Circuit : demande → validation → commande → réception (preuve) → validation comptable.

### 5.15 Comptabilité
Sélecteur de site, puis quatre boutons :
- **💰 Salaire et paie**, qui ouvre une seconde rangée :
  - **📊 Situation globale** : par défaut, avec les filtres et classements validés (site, bloc, catégorie, rôle, équipe, service, mois ou année) ; saisie directe dans les cases ; import et export Excel ;
  - **🌴 Congés** ;
  - **🤝 Prêts et avances** : retenue mensuelle = montant ÷ échéances ;
  - **🏅 Primes et bonus** : type Agent du mois, Gratification, Bonus mission, Autre (à préciser) ; proposition puis validation.
- **🛒 Achats** : validation des demandes d'achat.
- **🧾 Fournisseurs et factures** :
  - création d'un fournisseur avec la **catégorie en liste déroulante** (Carburant, Produits d'entretien, EPI et tenues, Matériel et équipements, Pièces et maintenance véhicules, Alimentation / cuisine, Fournitures de bureau, Télécommunications, Prestations de services, **Autre** à préciser) et la facturation (à chaque achat, ou mensuelle avec jour de clôture du cycle) ;
  - **⛽ STAR (Station)** : carburant par **bons d'achat**.
    - Photo obligatoire, lue par l'IA (fonction `bon-carburant`), puis corrigée et cochée « vérifié » avant validation.
    - Un N° de bon ne peut être enregistré qu'une fois.
    - Cycle du **20 au 20**, compte réglé tous les 30 jours.
    - « Facture du cycle » rattache les bons et contrôle l'écart avec le montant facturé.
- **💸 Dépenses diverses** (le carburant n'y figure plus) : flotte de véhicules, carburant repris des bons STAR, justificatifs.

Accès : direction, responsable et coordinateur des opérations, comptabilité, approvisionnement. Rapports financiers mensuels établis par l'IA.

### 5.16 Appels d'offres (veille)
Veille quotidienne (beta.mr, tendersinfo, globaltenders), **uniquement des prestations** de nettoyage, d'hygiène et de manutention. Onglet propre, pas sur l'accueil. Réservée à la direction et aux opérations.

### 5.17 Mon profil
- Coordonnées, mot de passe, préférences de notifications.
- Pour le seul responsable des opérations : outils d'administration (relais Gmail, « voir comme », suppression et mode test).

---

## 6. Données à rapprocher (personnel, magasin, comptabilité, signalements)

### 6.1 Méthode
1. Lire `jeu=catalogue`, puis `jeu=structure`.
2. Pour chaque domaine, comparer **ligne à ligne sur la clé métier** :

   | Domaine | Clé métier |
   |---|---|
   | Agents | `matricule` |
   | Comptes | téléphone ou e-mail |
   | Articles | nom + magasin |
   | Mouvements | id d'origine |
   | Signalements | `ref` / `bdm` |
   | Factures | fournisseur + numéro |
   | Bons carburant | fournisseur + numéro du bon |

3. Produire un **rapport d'écarts** :
   - absents d'un côté ;
   - champs différents (avant / après) ;
   - doublons ;
   - fiches marquées `tel_a_verifier`, `masque_listes`, départs.
4. **Corriger ITGHANE pour qu'il reflète EPS OPS.** Ne jamais écrire dans EPS OPS, sauf par le canal prévu (`itghane-entrant`) et pour les seuls comptes, documents et signatures.
5. Brancher ensuite le **flux `changements`** pour garder la concordance, avec `depuis_id` mémorisé côté ITGHANE.

### 6.2 Points d'attention connus
- « Sans Badge » n'est pas un numéro de badge.
- Les ex-employés gardent leur matricule. Leur départ est porté par `date_depart` et `actif = false`.
- Les chiffres de présence ne se recalculent pas : on reprend ceux des rapports et des appels.
- Les montants de renfort ne s'affichent jamais aux chefs d'équipe.
- Paie : période du 26 au 25 ; personnel administratif à salaire manuel (clé `adm:…`).

### 6.3 Jeux de données disponibles (catalogue de l'accès `itghane`, 75 jeux)
Tous sont lisibles dès maintenant (`jeu=<nom>`). Leurs modifications passent toutes par le flux `jeu=changements` et par l'envoi en temps réel.

| Domaine | Jeux |
|---|---|
| Personnel | `agents`, `nni`, `profils` (avec site, poste, e-mail), `horaires_individuels`, `parcours`, `documents_agents`, `demandes`, `interdits`, `import_classeurs`, `drive_journal` |
| Présence | `statuts` (avec retards `retard_*` et cas d'absence `cas_*`), `conges`, `appels`, `situations`, `suivi_absences`, `renforts`, `prises_service` |
| Discipline | `discipline` |
| Magasin | `magasins`, `articles` (avec `pour_manutention`), `mouvements_stock`, `besoins`, `dotations`, `dotation_quotas`, `magasin_seuils`, `bilans_magasin`, `commandes`, `commande_events` |
| Comptabilité | `recap_paie`, `paie_site`, `renforts_detail`, `grille_salaire`, `paie_ajustements`, `personnel_admin`, `sites`, `confirmations_essai`, `primes` (avec `type`), `prets_avances`, `fournisseurs` (avec `categorie`, `facturation`, `cycle_jour`), `factures`, `bons_carburant` (photo en lien temporaire), `depenses_diverses`, `vehicules` |
| Opérations | `vols`, `allocation_vol`, `rapports`, `checklists_vols`, `zones`, `postes`, `lieux`, `dispatch`, `signalements_zone`, `taches`, `taches_modeles`, `taches_notes`, `fauteuils`, `veille_ao` |
| Synthèse | `synthese_taches`, `synthese_alertes`, `evaluations`, `evaluations_agents` |
| Help Desk | `signalements` (avec `canal`, `attente_*`), `signalement_events`, `signalement_pj`, `sig_bdm_corrections` (à réserver à l'équipe opération), `bdm_recus`, `rapports_incident`, `rapports_incident_versions`, `rapports_incident_numeros`, `ir_archives`, `equipements`, `interventions`, `equipement_historique` |
| Traçabilité | `audit`, `acces` |

---

## 7. Rôles et droits (identiques à EPS OPS)

| Rôle (code) | Libellé | Accès principal |
|---|---|---|
| `direction` | Directeur des opérations | Tout, y compris Comptabilité et Appels d'offres |
| `responsable_ops` | Responsable des opérations | Tout ; administration ; approbation des modifications de demandes |
| `coordinateur_ops` | Coordinateur des opérations | Tout, y compris Comptabilité et Appels d'offres |
| `superviseur_principal` | Superviseur principal | Tout sauf la Comptabilité ; les deux services |
| `superviseur_nettoyage` / `superviseur_bagages` | Superviseur Nettoyage / Manutention | Exploitation de leur service, magasins (articles limités pour la Manutention), RH de leur site |
| `chef_nettoyage` / `chef_bagages` | Chef d'équipe | Exploitation de leur équipe, **sans magasin** (approvisionnement via Signalements), sans montant de renfort |
| `responsable_rh` / `assistante_rh` | RH | Tâches, shift, effectifs, présence, discipline, profil ; décisions sur retards et absences |
| `responsable_comptabilite` | Comptabilité | Comptabilité, achats, magasins (sans modifier les demandes), effectifs, présence, discipline |
| `responsable_technique` | Technique | Shift, tâches, signalements, technique, magasins, achats |
| `approvisionnement` | Approvisionnement | Magasins, achats, comptabilité, effectifs, présence, discipline |

Les droits sont appliqués **côté base** (règles d'accès RLS, `mon_role()`, `mon_site()`, `equipe_ops()`, fonctions serveur), pas seulement dans l'interface.

---

## 8. Livrables attendus

1. **Tableau de correspondance** des onglets ITGHANE ↔ EPS OPS, avec l'état de chacun (✅ / 🔄 / ➕ / 🟣) et la liste des écarts.
2. **Rapport de concordance des données** (§ 6.1), avec les comptes par table et les écarts nominatifs.
3. **Plan de mise à jour par lots**. Ordre conseillé :
   1. personnel et comptes ;
   2. présence, retards et absences ;
   3. signalements, Help Desk et rapports d'incident ;
   4. magasins ;
   5. comptabilité ;
   6. tâches (fauteuils roulants, grand ménage) ;
   7. le reste.
4. **Maquettes** de chaque écran modifié, à faire valider avant le code.
5. Après chaque lot : un **compte rendu** et la liste de ce qui reste.

**Ne rien supprimer, ne rien inventer, demander en cas de doute.**
