import React from 'react';
import Catalogue from './Catalogue';
export default function Recherche({ searchTerm, onLoginClick }) {
  return <Catalogue initialTerm={searchTerm} onLoginClick={onLoginClick} />;
}
