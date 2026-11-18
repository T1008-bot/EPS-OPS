# EPS OPS — points à faire

## Priorités actuelles
1. Ressources humaines : prise de présence et suivi de présence
2. Approvisionnement

## Plus tard (important, non prioritaire)
- **Pièces justificatives dans Supabase Storage** : copies signées des demandes d'explication,
  notifications de mise à pied, licenciements, mises en demeure, contrats ; rattachées au dossier
  de l'agent (matricule), accès réservé direction / RH.
- **Sauvegarde automatique vers Google Drive (compte archives EPS)** : connexion OAuth propre à
  l'app (fonction serveur Supabase `drive-archives` : déposer / lister / télécharger), export
  périodique de l'annuaire, des ex-employés et de l'historique disciplinaire.
  Prérequis : projet Google Cloud du compte archives EPS, API Drive, identifiant OAuth,
  écran de consentement « En production », jeton stocké dans les secrets Supabase.
- **Import des listes d'équipes depuis l'app** (comparatif avant application), y compris Nettoyage.
- Nettoyage : appliquer le classeur du 16/11 à l'annuaire (comparatif à valider).
- **Demandes d'explication signées via formulaire** : formulaire Jotform (émission, réponse de
  l'agent + signature, avis du superviseur principal + signature) ; lecture par `jotform-sync`,
  rattachement à l'agent (matricule/badge) et à la DE existante (référence), mise en forme avec le
  modèle actuel de l'app (`docHTML`), signatures intégrées, PDF archivé dans Supabase Storage et
  consultable depuis la carte de l'agent. À trancher : un seul formulaire ou lien personnel envoyé
  à l'agent ; émission dans l'app ou sur Jotform ; signature de l'émetteur ; même circuit pour les
  notifications de mise à pied (accusé de réception).

## Présence (validé, à développer)
- **Appel dans l'app** par le chef d'équipe : tous présents par défaut, il coche les exceptions
  (NJ, J, congé, retard + heure, renforts), confirme ; bouton « Remplir le formulaire » vers la
  Situation du staff Jotform préremplie (les deux sont conservés) ; PDF ; export Excel sur période.
- **Retards automatiques** : absent le matin, présent à la situation de 17h → « retard à confirmer »
  validé par le chef/superviseur.
- **Relance de l'appel dès 9h15** (à intégrer aux rappels de prise de service existants).
- Récap mensuel paie (26→25) : présents, NJ, J, congés, MAP, retards ; **prime agent du mois** à part
  (sélection des bénéficiaires) ; pas de permissions.
- Alertes RH : 2 absences NJ consécutives (boutons « Convoquer » + date de rendez-vous, et DE) ;
  sans nouvelles depuis 5 jours ; après 2 shifts sans nouvelles → alerte « ne pas monter » au
  responsable des opérations, superviseurs du service, chefs d'équipe concernés, RH.

## En attente (modifications faites dans Claude chat, 18/11)
- Table « horaires de référence » (STA/STD saisies par un superviseur) : accord requis.
- Choix éventuel d'un service d'horaires payant (AeroAPI ou Aviation Edge).
- Validation des horaires des tâches de nettoyage proposés.
- Dispatching : formulaire Staff Dispatching à passer en listes de matricules.
- Présence N2 / M2 « doivent apparaître automatiquement » : besoin à clarifier.
- Position jointe aux signalements : faisable, non fait.
- Page publique « Vols réguliers NKC » figée sur le 18–24/11 : à remplacer ou mettre à jour.
- Situation du recrutement à renseigner (config_alertes.recrutement).
- Nouveautés du 18/11 non vérifiées dans l'application ouverte.
