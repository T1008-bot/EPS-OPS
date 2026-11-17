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
