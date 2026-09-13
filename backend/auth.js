const express = require('express');
const bcrypt = require('bcrypt');
const jwt = require('jsonwebtoken');
const db = require('./database');

const router = express.Router();
const JWT_SECRET = require('./legacy-config').JWT_SECRET;

// Inscription
router.post('/register', async (req, res) => {
  const { nom, email, mot_de_passe } = req.body;

  if (!nom || !email || !mot_de_passe) {
    return res.status(400).json({ error: 'Tous les champs sont obligatoires' });
  }

  if (mot_de_passe.length < 6) {
    return res.status(400).json({ error: 'Le mot de passe doit faire au moins 6 caractères' });
  }

  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  if (!emailRegex.test(email)) {
    return res.status(400).json({ error: 'Email invalide' });
  }

  try {
    const existant = db.prepare('SELECT id FROM clients WHERE email = ?').get(email);
    if (existant) {
      return res.status(409).json({ error: 'Cet email est déjà utilisé' });
    }

    const hash = await bcrypt.hash(mot_de_passe, 10);

    const result = db.prepare(
      'INSERT INTO clients (nom, email, mot_de_passe) VALUES (?, ?, ?)'
    ).run(nom, email.toLowerCase(), hash);

    const token = jwt.sign(
      { id: result.lastInsertRowid, nom, email, role: 'artisan' },
      JWT_SECRET,
      { expiresIn: '7d' }
    );

    res.status(201).json({ token, user: { id: result.lastInsertRowid, nom, email, role: 'artisan' } });
  } catch (err) {
    console.error('Erreur inscription:', err);
    res.status(500).json({ error: 'Erreur serveur' });
  }
});

// Connexion
router.post('/login', async (req, res) => {
  const { email, mot_de_passe } = req.body;

  if (!email || !mot_de_passe) {
    return res.status(400).json({ error: 'Email et mot de passe requis' });
  }

  try {
    const client = db.prepare('SELECT * FROM clients WHERE email = ?').get(email.toLowerCase());
    if (!client) {
      return res.status(401).json({ error: 'Email ou mot de passe incorrect' });
    }

    const valide = await bcrypt.compare(mot_de_passe, client.mot_de_passe);
    if (!valide) {
      return res.status(401).json({ error: 'Email ou mot de passe incorrect' });
    }

    const token = jwt.sign(
      { id: client.id, nom: client.nom, email: client.email, role: client.role },
      JWT_SECRET,
      { expiresIn: '7d' }
    );

    res.json({ token, user: { id: client.id, nom: client.nom, email: client.email, role: client.role } });
  } catch (err) {
    console.error('Erreur connexion:', err);
    res.status(500).json({ error: 'Erreur serveur' });
  }
});

// Vérifier le token (pour le frontend)
router.get('/me', (req, res) => {
  const authHeader = req.headers.authorization;
  if (!authHeader) return res.status(401).json({ error: 'Non authentifié' });

  const token = authHeader.split(' ')[1];
  try {
    const decoded = jwt.verify(token, JWT_SECRET);
    res.json({ user: { id: decoded.id, nom: decoded.nom, email: decoded.email, role: decoded.role } });
  } catch {
    res.status(401).json({ error: 'Token invalide ou expiré' });
  }
});

module.exports = router;
