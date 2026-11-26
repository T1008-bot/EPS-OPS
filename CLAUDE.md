# EPS OPS — règles de travail

- Toujours répondre en français.
- **« Équipe opération »** = responsable des opérations, directeur des opérations (Sidahmed Labeid, poste « Directeur des opérations »),
  coordinateur des opérations, consultant RH et opérations (Abdallahi Labeid) et superviseurs principaux.
  Côté base : fonction `equipe_ops()` (roles responsable_ops, coordinateur_ops, superviseur_principal, ou direction avec poste « Directeur des op… »).
- Vocabulaire : « Manutention bagages » (jamais « bagage » ou « bagagiste » seul). Le montant du renfort (500 MRU) n'est pas affiché aux chefs.
- Migrations : éviter DROP/DELETE/cascade (préférer des indicateurs : retire, annule, supprime_le).
- Maquette à faire valider avant tout changement de mise en page.
- Déploiement : vérifier la syntaxe, incrémenter `eps-ops-vN` dans sw.js, ajouter une note dans docs/sql/appel_presence_essai.sql, pousser la branche puis main.
- Comptes : identifiant = n° de téléphone (`<tel>@eps-ops.mr`) et mot de passe initial = même numéro (changement forcé à la 1re connexion).
  Si on corrige le numéro d'une personne qui ne s'est jamais connectée, mettre à jour l'identifiant ET le mot de passe initial.
- Navigation : toute page ouverte depuis une autre page affiche un bouton « ← Retour » (navGo / navback, bouton retour du téléphone géré). Les cartes de l’accueil ouvrent une page séparée, elles ne se déplient pas.
- Vérifier après chaque déploiement que `const C="eps-ops-vN"` dans sw.js a bien changé (grep), sinon les téléphones ne reçoivent pas la mise à jour.
