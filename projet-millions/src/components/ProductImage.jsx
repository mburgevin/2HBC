import React, { useState } from 'react';
import { safeUrl } from '../lib/data';

export default function ProductImage({ product, compact = false }) {
  const src = safeUrl(product.image_url);
  const [failedUrl, setFailedUrl] = useState(null);
  const visible = src && src !== failedUrl;
  return <div className={'product-image' + (compact ? ' product-image--compact' : '')}>
    {visible ? <img key={src} src={src} alt={product.nom} loading="lazy" decoding="async"
      referrerPolicy="no-referrer" onError={() => setFailedUrl(src)} /> :
      <span className="product-image-placeholder">
        <svg width="38" height="38" viewBox="0 0 40 40" fill="none" aria-hidden="true">
          <rect x="5" y="5" width="30" height="30" rx="5" stroke="currentColor" strokeWidth="1.5" />
          <circle cx="14" cy="14" r="3" stroke="currentColor" strokeWidth="1.5" />
          <path d="m7 30 9-9 6 6 5-5 7 8" stroke="currentColor" strokeWidth="1.5" />
        </svg>
        <span>Visuel à venir</span>
      </span>}
  </div>;
}
