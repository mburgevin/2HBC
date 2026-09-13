import { useEffect, useState } from "react";
import { useAuth } from "./AuthContext";

const API = "http://localhost:4000";

// Configuration par fournisseur
// cartUrl    : page panier (ouverture onglet)
// addToCart  : endpoint pour ajouter au panier (POST, requiert CSRF session → non utilisable cross-origin)
// apiUrl     : endpoint API officielle partenaire (null = pas encore intégré)
const FOURNISSEUR_CONFIG = {
  Rexel: {
    cartUrl: "https://www.rexel.fr/frx/cart",
    addToCart: "https://www.rexel.fr/frx/cart/addProductToCart",
    apiUrl: null,
    label: "Rexel",
    csvSeparator: ";",
    csvHeaders: "ID Rexel;Référence;Désignation;Quantité",
    buildCsvRow: (item) =>
      `${item.rexel_product_id || ""};${item.rexel_product_code || item.ref_fabricant};${item.nom || ""};${item.quantite}`,
  },
  Sonepar: {
    cartUrl: "https://www.sonepar.fr/cart",
    addToCart: null,
    apiUrl: null,
    label: "Sonepar",
    csvSeparator: ";",
    csvHeaders: "Référence fabricant;Quantité",
    buildCsvRow: (item) => `${item.ref_fabricant};${item.quantite}`,
  },
  Yesss: {
    cartUrl: "https://www.yesss.fr/cart",
    addToCart: null,
    apiUrl: null,
    label: "Yesss",
    csvSeparator: ";",
    csvHeaders: "Référence fabricant;Quantité",
    buildCsvRow: (item) => `${item.ref_fabricant};${item.quantite}`,
  },
  Yess: {
    cartUrl: "https://www.yesss.fr/cart",
    addToCart: null,
    apiUrl: null,
    label: "Yesss",
    csvSeparator: ";",
    csvHeaders: "Référence fabricant;Quantité",
    buildCsvRow: (item) => `${item.ref_fabricant};${item.quantite}`,
  },
};

// Génère et télécharge un fichier CSV pour le fournisseur
function telechargerCSV(fournisseur, items, config) {
  const lignes = [config.csvHeaders, ...items.map(config.buildCsvRow)];
  const contenu = lignes.join("\n");
  const blob = new Blob(["\uFEFF" + contenu], { type: "text/csv;charset=utf-8;" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `commande_${fournisseur.toLowerCase()}_2hbc.csv`;
  a.click();
  URL.revokeObjectURL(url);
}

export default function Panier() {
  useAuth(); // garde le contexte auth actif
  const token = localStorage.getItem('token');
  const [articles, setArticles] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [redirecting] = useState(null);
  const [modalCommande, setModalCommande] = useState(null); // { fournisseur, items }

  // Charger le panier
  const fetchPanier = async () => {
    try {
      setLoading(true);
      const res = await fetch(`${API}/api/panier`, {
        headers: { Authorization: `Bearer ${token}` },
      });
      if (!res.ok) throw new Error("Erreur chargement panier");
      const data = await res.json();
      setArticles(data);
    } catch (e) {
      setError(e.message);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (token) fetchPanier();
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [token]);

  // Modifier la quantité d'un article
  const updateQuantite = async (articleId, nouvelleQte) => {
    if (nouvelleQte < 1) {
      supprimerArticle(articleId);
      return;
    }
    try {
      await fetch(`${API}/api/panier/${articleId}`, {
        method: "PATCH",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ quantite: nouvelleQte }),
      });
      setArticles((prev) =>
        prev.map((a) =>
          a.id === articleId ? { ...a, quantite: nouvelleQte } : a
        )
      );
    } catch (e) {
      console.error("Erreur modification quantité", e);
    }
  };

  // Supprimer un article
  const supprimerArticle = async (articleId) => {
    try {
      await fetch(`${API}/api/panier/${articleId}`, {
        method: "DELETE",
        headers: { Authorization: `Bearer ${token}` },
      });
      setArticles((prev) => prev.filter((a) => a.id !== articleId));
    } catch (e) {
      console.error("Erreur suppression", e);
    }
  };

  // Tout commander : CSV + onglet pour chaque fournisseur
  const toutCommander = () => {
    const groupes = grouperParFournisseur(articles);
    const entries = Object.entries(groupes);

    entries.forEach(([fournisseur, items]) => {
      const config = FOURNISSEUR_CONFIG[fournisseur];
      if (!config) return;
      telechargerCSV(fournisseur, items, config);
      window.open(config.cartUrl, "_blank");
    });

    // Modal sur le premier fournisseur
    if (entries.length > 0) {
      const [fournisseur, items] = entries[0];
      const config = FOURNISSEUR_CONFIG[fournisseur];
      if (config) setModalCommande({ fournisseur, items, config });
    }
  };

  // Commander chez un fournisseur : CSV + ouverture du panier
  const redirectFournisseur = (fournisseur, items) => {
    const config = FOURNISSEUR_CONFIG[fournisseur];
    if (!config) {
      alert(`Fournisseur non configuré : ${fournisseur}`);
      return;
    }
    // Télécharger le CSV de commande
    telechargerCSV(fournisseur, items, config);
    // Ouvrir la page panier du fournisseur
    window.open(config.cartUrl, "_blank");
    // Afficher la modal avec instructions
    setModalCommande({ fournisseur, items, config });
  };

  // Grouper les articles par fournisseur (champ `fournisseur` sur chaque article)
  const grouperParFournisseur = (articles) => {
    return articles.reduce((acc, article) => {
      const f = article.fournisseur || "Non défini";
      if (!acc[f]) acc[f] = [];
      acc[f].push(article);
      return acc;
    }, {});
  };

  if (!token) {
    return (
      <div style={styles.emptyWrap}>
        <div style={styles.emptyBox}>
          <span style={styles.emptyIcon}>🔒</span>
          <p style={styles.emptyText}>Connectez-vous pour voir votre panier.</p>
        </div>
      </div>
    );
  }

  if (loading) {
    return (
      <div style={styles.emptyWrap}>
        <div style={styles.loader} />
      </div>
    );
  }

  if (error) {
    return (
      <div style={styles.emptyWrap}>
        <p style={{ color: "#e74c3c" }}>{error}</p>
      </div>
    );
  }

  if (articles.length === 0) {
    return (
      <div style={styles.emptyWrap}>
        <div style={styles.emptyBox}>
          <span style={styles.emptyIcon}>🛒</span>
          <p style={styles.emptyText}>Votre panier est vide.</p>
        </div>
      </div>
    );
  }

  const groupes = grouperParFournisseur(articles);

  return (
    <div style={styles.page}>
      {/* Header panier */}
      <div style={styles.pageHeader}>
        <h2 style={styles.titre}>Détail du panier</h2>
        <button style={styles.btnToutCommander} onClick={toutCommander}>
          Tout commander
        </button>
      </div>

      {/* Table header */}
      <div style={styles.tableHeader}>
        <span style={styles.colFournisseur}>Fournisseurs</span>
        <span style={styles.colProduits}>Produits</span>
        <span style={styles.colQuantite}>Quantité</span>
      </div>

      {/* Modal commande rapide */}
      {modalCommande && (
        <ModalCommandeRapide
          fournisseur={modalCommande.fournisseur}
          items={modalCommande.items}
          config={modalCommande.config}
          onClose={() => setModalCommande(null)}
        />
      )}

      {/* Groupes par fournisseur */}
      {Object.entries(groupes).map(([fournisseur, items]) => (
        <div key={fournisseur} style={styles.groupe}>
          {/* Ligne fournisseur */}
          <div style={styles.fournisseurRow}>
            <span style={styles.fournisseurNom}>
              <span style={styles.triangle}>▼</span> {fournisseur}
            </span>
            <button
              style={{
                ...styles.btnCommander,
                opacity: redirecting === fournisseur ? 0.7 : 1,
              }}
              onClick={() => redirectFournisseur(fournisseur, items)}
              disabled={redirecting === fournisseur}
            >
              {redirecting === fournisseur ? "Redirection..." : "Commander"}
            </button>
          </div>

          {/* Articles de ce fournisseur */}
          {items.map((article) => (
            <div key={article.id} style={styles.articleCard}>
              {/* Image */}
              <div style={styles.imgWrap}>
                {article.image_url ? (
                  <img
                    src={article.image_url}
                    alt={article.nom}
                    style={styles.img}
                  />
                ) : (
                  <div style={styles.imgPlaceholder}>📦</div>
                )}
              </div>

              {/* Infos produit */}
              <div style={styles.articleInfo}>
                <p style={styles.articleNom}>{article.nom}</p>
                <p style={styles.articleRef}>Réf Fab : {article.ref_fabricant}</p>
                <ul style={styles.specs}>
                  {article.specificite &&
                    String(article.specificite)
                      .split(/[;\n]/)
                      .filter(Boolean)
                      .slice(0, 5)
                      .map((s, i) => (
                        <li key={i} style={styles.specItem}>
                          {s.trim()}
                        </li>
                      ))}
                </ul>
              </div>

              {/* Quantité + supprimer */}
              <div style={styles.qteWrap}>
                <div style={styles.qteBox}>
                  <button
                    style={styles.qteBtn}
                    onClick={() =>
                      updateQuantite(article.id, article.quantite - 1)
                    }
                  >
                    −
                  </button>
                  <span style={styles.qteVal}>{article.quantite}</span>
                  <button
                    style={styles.qteBtn}
                    onClick={() =>
                      updateQuantite(article.id, article.quantite + 1)
                    }
                  >
                    +
                  </button>
                </div>
                <button
                  style={styles.btnSupp}
                  onClick={() => supprimerArticle(article.id)}
                  title="Supprimer"
                >
                  ✕
                </button>
              </div>
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}

/* ─── Modal Commande Rapide ─── */
function ModalCommandeRapide({ fournisseur, items, config, onClose }) {
  const [csvRetelecharge, setCsvRetelecharge] = useState(false);

  const retelecharger = () => {
    telechargerCSV(fournisseur, items, config);
    setCsvRetelecharge(true);
    setTimeout(() => setCsvRetelecharge(false), 2000);
  };

  return (
    <div style={mStyles.overlay} onClick={onClose}>
      <div style={mStyles.box} onClick={(e) => e.stopPropagation()}>
        <button style={mStyles.close} onClick={onClose}>✕</button>

        <h3 style={mStyles.titre}>Finaliser votre commande {config.label}</h3>

        <div style={mStyles.steps}>
          <div style={mStyles.step}>
            <span style={mStyles.stepNum}>1</span>
            <span>Un fichier <strong>commande_{fournisseur.toLowerCase()}_2hbc.csv</strong> vient d'être téléchargé sur votre ordinateur.</span>
          </div>
          <div style={mStyles.step}>
            <span style={mStyles.stepNum}>2</span>
            <span>Sur la page <strong>{config.label}</strong> qui s'est ouverte, connectez-vous à votre compte professionnel.</span>
          </div>
          <div style={mStyles.step}>
            <span style={mStyles.stepNum}>3</span>
            <span>Utilisez la fonction <strong>"Commande rapide"</strong> ou <strong>"Importer une liste"</strong> et uploadez le CSV.</span>
          </div>
        </div>

        <div style={mStyles.tableWrap}>
          <table style={mStyles.table}>
            <thead>
              <tr>
                {fournisseur === "Rexel" && <th style={mStyles.th}>ID Rexel</th>}
                <th style={mStyles.th}>Référence</th>
                <th style={mStyles.th}>Désignation</th>
                <th style={mStyles.th}>Qté</th>
              </tr>
            </thead>
            <tbody>
              {items.map((item) => (
                <tr key={item.id}>
                  {fournisseur === "Rexel" && (
                    <td style={{ ...mStyles.td, color: "#64748b", fontSize: 11 }}>
                      {item.rexel_product_id || "—"}
                    </td>
                  )}
                  <td style={mStyles.td}>{item.rexel_product_code || item.ref_fabricant}</td>
                  <td style={{ ...mStyles.td, maxWidth: 180, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                    {item.nom || "—"}
                  </td>
                  <td style={{ ...mStyles.td, textAlign: "center" }}>{item.quantite}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div style={mStyles.actions}>
          <button style={mStyles.btnCopier} onClick={retelecharger}>
            {csvRetelecharge ? "✓ Téléchargé !" : "Re-télécharger le CSV"}
          </button>
          <a
            href={config.cartUrl}
            target="_blank"
            rel="noopener noreferrer"
            style={mStyles.btnQuick}
          >
            Ouvrir {config.label} →
          </a>
        </div>
      </div>
    </div>
  );
}

/* ─── Styles ─── */
const C = {
  teal: "#1a9ba1",
  tealDark: "#17858a",
  navy: "#2c3e50",
  border: "#e2e8f0",
  bg: "#f8fafc",
  text: "#334155",
  muted: "#64748b",
  white: "#ffffff",
  red: "#e74c3c",
};

const styles = {
  page: {
    maxWidth: 860,
    margin: "32px auto",
    padding: "0 16px 60px",
    fontFamily: "'Segoe UI', system-ui, sans-serif",
    color: C.text,
  },
  pageHeader: {
    display: "flex",
    justifyContent: "space-between",
    alignItems: "center",
    marginBottom: 24,
  },
  titre: {
    fontSize: 22,
    fontWeight: 700,
    color: C.navy,
    margin: 0,
  },
  btnToutCommander: {
    background: C.navy,
    color: C.white,
    border: "none",
    borderRadius: 6,
    padding: "10px 22px",
    fontWeight: 600,
    fontSize: 14,
    cursor: "pointer",
  },
  tableHeader: {
    display: "grid",
    gridTemplateColumns: "180px 1fr 120px",
    borderBottom: `2px solid ${C.border}`,
    paddingBottom: 10,
    marginBottom: 8,
    fontWeight: 600,
    fontSize: 14,
    color: C.muted,
  },
  colFournisseur: {},
  colProduits: {},
  colQuantite: { textAlign: "center" },

  groupe: {
    marginBottom: 28,
    borderRadius: 10,
    border: `1px solid ${C.border}`,
    overflow: "hidden",
    background: C.white,
    boxShadow: "0 1px 4px rgba(0,0,0,0.06)",
  },
  fournisseurRow: {
    display: "flex",
    alignItems: "center",
    gap: 16,
    padding: "14px 20px",
    background: C.bg,
    borderBottom: `1px solid ${C.border}`,
  },
  triangle: { fontSize: 10, color: C.muted },
  fournisseurNom: {
    fontWeight: 700,
    fontSize: 16,
    color: C.navy,
    flex: 1,
  },
  btnCommander: {
    background: C.navy,
    color: C.white,
    border: "none",
    borderRadius: 6,
    padding: "8px 18px",
    fontWeight: 600,
    fontSize: 13,
    cursor: "pointer",
    transition: "opacity 0.2s",
  },

  articleCard: {
    display: "grid",
    gridTemplateColumns: "80px 1fr 120px",
    alignItems: "center",
    gap: 16,
    padding: "16px 20px",
    borderBottom: `1px solid ${C.border}`,
  },
  imgWrap: {
    width: 80,
    height: 70,
    borderRadius: 8,
    border: `1px solid ${C.border}`,
    overflow: "hidden",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    background: C.bg,
  },
  img: { width: "100%", height: "100%", objectFit: "contain" },
  imgPlaceholder: { fontSize: 28 },

  articleInfo: { flex: 1 },
  articleNom: {
    fontWeight: 600,
    fontSize: 13,
    color: C.navy,
    margin: "0 0 2px",
    lineHeight: 1.4,
  },
  articleRef: {
    fontSize: 12,
    color: C.muted,
    margin: "0 0 6px",
  },
  specs: {
    margin: 0,
    padding: "0 0 0 14px",
    listStyle: "disc",
  },
  specItem: {
    fontSize: 12,
    color: C.muted,
    lineHeight: 1.6,
  },

  qteWrap: {
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    gap: 8,
  },
  qteBox: {
    display: "flex",
    alignItems: "center",
    border: `1.5px solid ${C.border}`,
    borderRadius: 20,
    overflow: "hidden",
    background: C.white,
  },
  qteBtn: {
    width: 30,
    height: 30,
    border: "none",
    background: "transparent",
    fontSize: 16,
    cursor: "pointer",
    color: C.teal,
    fontWeight: 700,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
  },
  qteVal: {
    minWidth: 28,
    textAlign: "center",
    fontWeight: 700,
    fontSize: 14,
    color: C.navy,
  },
  btnSupp: {
    background: "transparent",
    border: "none",
    color: "#cbd5e1",
    fontSize: 14,
    cursor: "pointer",
    padding: 4,
    borderRadius: 4,
    transition: "color 0.2s",
  },

  emptyWrap: {
    display: "flex",
    justifyContent: "center",
    alignItems: "center",
    minHeight: 300,
  },
  emptyBox: {
    textAlign: "center",
  },
  emptyIcon: { fontSize: 48 },
  emptyText: {
    marginTop: 12,
    color: C.muted,
    fontSize: 16,
  },
  loader: {
    width: 40,
    height: 40,
    border: `4px solid ${C.border}`,
    borderTop: `4px solid ${C.teal}`,
    borderRadius: "50%",
    animation: "spin 0.8s linear infinite",
  },
};

const mStyles = {
  overlay: {
    position: "fixed",
    inset: 0,
    background: "rgba(0,0,0,0.5)",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    zIndex: 1000,
    padding: 16,
  },
  box: {
    background: "#fff",
    borderRadius: 12,
    padding: "28px 32px",
    maxWidth: 560,
    width: "100%",
    position: "relative",
    boxShadow: "0 8px 40px rgba(0,0,0,0.18)",
  },
  close: {
    position: "absolute",
    top: 14,
    right: 16,
    background: "none",
    border: "none",
    fontSize: 18,
    cursor: "pointer",
    color: C.muted,
  },
  titre: {
    fontSize: 18,
    fontWeight: 700,
    color: C.navy,
    marginTop: 0,
    marginBottom: 10,
  },
  desc: {
    fontSize: 14,
    color: C.text,
    lineHeight: 1.6,
    marginBottom: 16,
  },
  steps: {
    display: "flex",
    flexDirection: "column",
    gap: 10,
    marginBottom: 16,
    background: "#f0fdf4",
    borderRadius: 8,
    padding: "12px 16px",
    border: "1px solid #bbf7d0",
  },
  step: {
    display: "flex",
    alignItems: "flex-start",
    gap: 10,
    fontSize: 13,
    color: C.text,
    lineHeight: 1.5,
  },
  stepNum: {
    background: C.teal,
    color: "#fff",
    borderRadius: "50%",
    width: 20,
    height: 20,
    minWidth: 20,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    fontSize: 11,
    fontWeight: 700,
    marginTop: 1,
  },
  tableWrap: {
    border: `1px solid ${C.border}`,
    borderRadius: 8,
    overflow: "hidden",
    marginBottom: 16,
  },
  table: {
    width: "100%",
    borderCollapse: "collapse",
    fontSize: 13,
  },
  th: {
    background: C.bg,
    padding: "8px 12px",
    textAlign: "left",
    fontWeight: 600,
    color: C.muted,
    borderBottom: `1px solid ${C.border}`,
  },
  td: {
    padding: "8px 12px",
    color: C.text,
    borderBottom: `1px solid ${C.border}`,
    fontFamily: "monospace",
  },
  actions: {
    display: "flex",
    gap: 10,
    flexWrap: "wrap",
    marginBottom: 14,
  },
  btnCopier: {
    background: C.teal,
    color: "#fff",
    border: "none",
    borderRadius: 6,
    padding: "10px 18px",
    fontWeight: 600,
    fontSize: 13,
    cursor: "pointer",
    flex: 1,
  },
  btnQuick: {
    background: C.navy,
    color: "#fff",
    border: "none",
    borderRadius: 6,
    padding: "10px 18px",
    fontWeight: 600,
    fontSize: 13,
    cursor: "pointer",
    flex: 1,
    textDecoration: "none",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
  },
  note: {
    fontSize: 12,
    color: C.muted,
    margin: 0,
    lineHeight: 1.5,
  },
};
