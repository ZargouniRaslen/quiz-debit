# Quiz Débitmètres — quiz en direct (type Kahoot)

Site statique (HTML/CSS/JS, aucun build) + Supabase (base, auth, temps réel) + Vercel.
Le temps et les points sont calculés par la base ; la bonne réponse n'est révélée qu'à la clôture de la question.

## Fonctionnalités (portées depuis quiz-chine, sans thème chinois)

- **Nombre de questions libre** : 1 à 200 (boutons rapides ou saisie). Un quiz doit contenir au moins une question pour être lancé.
- **Éditeur avancé** : cartes repliables, ajouter / dupliquer / monter / descendre / supprimer, Ctrl/⌘+S, statut de complétion par question, toast avec annulation.
- **Comptes** : tout utilisateur Supabase connecté est animateur (pas de code secret). Pour restreindre, désactivez les nouvelles inscriptions dans le dashboard Supabase après avoir créé votre compte.
- **Plus de code de groupe** pour les binômes.
- **QR code** dans la salle d'attente (lien direct `#/join/CODE`).
- **Réponses anticipées** autorisées pendant le compte à rebours « Préparez-vous ».
- **Marge serveur** réduite à 1 s après la fin du chrono.
- **Pas d'auto-avance** : le host attend la fin du décompte ou le bouton « Passer le temps ».
- **Cérémonie de podium** animée sur l'écran animateur (3e → 2e → 1er).
- **Thème clair / sombre** (bouton ◐ en haut à droite, mémorisé).
- **Formes de réponses** style Kahoot (triangle, losange, cercle, carré).

## Mise en ligne

1. Supabase : *SQL Editor* → collez **tout** `supabase/setup.sql` → *Run*.  
   ⚠ Ce fichier **efface** d'abord toutes les tables du schéma `public` puis recrée tout (comptes Authentication conservés).  
   **Base déjà en service ?** N'exécutez PAS `setup.sql` : utilisez les migrations non destructives (`migration_quizzes.sql`, `migration_early_answers.sql`, `upgrade_n_questions.sql` / `live_migration.sql` selon le cas).
2. *Authentication → Providers → Email* : activé. Pour un flux simple, désactivez **Confirm email**.
3. (Optionnel) Pour limiter qui peut devenir animateur : désactivez les nouvelles inscriptions après avoir créé votre compte.
4. Realtime : rien à configurer (Broadcast uniquement).
5. `config.js` : URL + clé anon/publishable. Puis GitHub → Vercel (Framework *Other*, aucun build).

## Utilisation

- **Animateur** : `#/admin` → créer un compte (ou se connecter) → **Nouveau quiz** : choisissez le nombre de questions (1–200), remplissez-les, **Enregistrer**.  
  Vous pouvez rouvrir un quiz pour ajouter, dupliquer, déplacer ou supprimer des questions (Ctrl/⌘+S).  
  Sur un tableau de bord vide, **Importer le quiz « Débitmètres (exemple) »** ajoute un quiz d'exemple.  
  Puis **Lancer** → code à 4 lettres → **Démarrer**. Espace / → = Continuer.
- **Joueurs** : page d'accueil → code (ou scan QR) → Seul / Binôme → noms → salle d'attente.
- Déroulé : préparation 3 s → question → résultats → classement → question suivante ; classement final, cérémonie et export PDF.
- Remise à zéro : `truncate sessions cascade;`

## Barème

Bonne réponse : `round(1000 × (1 − 0.5 × temps / durée))` (1000 pts si instantané, 500 au dernier moment). Faux ou absent : 0.  
Classement : points ↓, bonnes réponses ↓, temps total ↑.
