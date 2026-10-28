import React, { useState } from 'react';

export default function CatalogueFilters({ facets, categories, filters, onChange, disabled }) {
  const change = (key, value) => {
    const next = { ...filters };
    if (value == null || (Array.isArray(value) && !value.length)) delete next[key];
    else next[key] = value;
    onChange(next);
  };
  const toggle = (key, value) => {
    const current = Array.isArray(filters[key]) ? filters[key] : [];
    change(key, current.includes(value) ? current.filter(v => v !== value) : [...current, value]);
  };
  const counts = new Map((facets.find(f => f.key === 'categorie')?.values || []).map(v => [v.value, v.count]));
  const branches = (parent = null, depth = 0) => categories.filter(c => c.parent_id === parent).flatMap(c => [
    <option value={c.code} key={c.code}>{'— '.repeat(depth)}{c.nom} ({counts.get(c.code) || 0})</option>,
    ...branches(c.id, depth + 1)
  ]);
  // Keep selected facets removable even when another filter has no matches.
  const visible = [...facets.filter(f => f.key !== 'categorie')];
  for (const key of Object.keys(filters)) {
    if (key !== 'categorie' && !visible.some(f => f.key === key)) visible.push({ key, label: key.replace('a:', ''), values: [] });
  }
  return <aside className="catalogue-filters" aria-label="Filtres du catalogue">
    <div className="filter-heading"><h2>Affiner la recherche</h2><button className="text-button" disabled={disabled || !Object.keys(filters).length} onClick={() => onChange({})}>Tout effacer</button></div>
    <fieldset disabled={disabled}>
      <label htmlFor="category-filter">Catégorie</label>
      <select id="category-filter" value={filters.categorie?.[0] || ''} onChange={e => change('categorie', e.target.value ? [e.target.value] : [])}>
        <option value="">Toutes les catégories</option>{branches()}
      </select>
      {visible.map(facet => {
        const selected = Array.isArray(filters[facet.key]) ? filters[facet.key] : [];
        const values = [...facet.values, ...selected.filter(v => !facet.values.some(x => x.value === v)).map(v => ({ value: v, label: v, count: 0 }))];
        return <details open key={facet.key} className="filter-group">
          <summary>{facet.label}{facet.unit ? ` (${facet.unit})` : ''}</summary>
          <div className="facet-values">{values.map(v => <label key={v.value}>
            <input type="checkbox" checked={selected.includes(v.value)} onChange={() => toggle(facet.key, v.value)} />
            <span>{v.label}</span><small>{v.count}</small>
          </label>)}</div>
          {facet.type === 'number' && <NumericRange key={JSON.stringify(filters[facet.key])} facet={facet} value={filters[facet.key]} onChange={value => change(facet.key, value)} />}
          {filters[facet.key] && <button className="text-button" onClick={() => change(facet.key, null)}>Effacer {facet.label.toLowerCase()}</button>}
        </details>;
      })}
    </fieldset>
  </aside>;
}

function NumericRange({ facet, value, onChange }) {
  const [min, setMin] = useState(!Array.isArray(value) ? value?.min ?? '' : '');
  const [max, setMax] = useState(!Array.isArray(value) ? value?.max ?? '' : '');
  const valid = (min === '' || Number.isFinite(Number(min))) && (max === '' || Number.isFinite(Number(max))) && (min === '' || max === '' || Number(min) <= Number(max));
  return <form className="facet-range" onSubmit={e => {
    e.preventDefault();
    if (!valid) return;
    const range = {};
    if (min !== '') range.min = Number(min);
    if (max !== '') range.max = Number(max);
    onChange(Object.keys(range).length ? range : null);
  }}>
    <label>Min.<input aria-label={`${facet.label} minimum`} type="number" min="0" step="any" value={min} onChange={e => setMin(e.target.value)} /></label>
    <label>Max.<input aria-label={`${facet.label} maximum`} type="number" min="0" step="any" value={max} onChange={e => setMax(e.target.value)} /></label>
    <button className="secondary" disabled={!valid}>Appliquer</button>
  </form>;
}
