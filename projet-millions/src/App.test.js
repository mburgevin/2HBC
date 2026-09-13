import { render, screen, fireEvent } from '@testing-library/react';
import App from './App';
import { useAuth } from './components/AuthContext';
import { listProducts } from './lib/data';
jest.mock('./lib/supabase', () => ({ isConfigured: true }));
jest.mock('./components/AuthContext', () => ({ AuthProvider: ({ children }) => children, useAuth: jest.fn() }));
jest.mock('./lib/data', () => ({ ...jest.requireActual('./lib/data'), listProducts: jest.fn() }));
beforeEach(() => { useAuth.mockReturnValue({ user: null, loading: false, logout: jest.fn(), recovery: false }); listProducts.mockResolvedValue([]); });
test('Accueil et navigation vers le catalogue', async () => {
 render(<App />); expect(screen.getByRole('heading', {name:/Préparez vos achats/})).toBeInTheDocument();
 fireEvent.click(screen.getByRole('button',{name:'Explorer le catalogue'}));
 expect(await screen.findByRole('heading',{name:'Aucun produit trouvé'})).toBeInTheDocument();
});
test('Erreur réseau affichée avec réessai', async () => {
 listProducts.mockRejectedValue(new Error('offline')); render(<App />);
 fireEvent.click(screen.getByRole('button',{name:'Explorer le catalogue'}));
 expect(await screen.findByRole('alert')).toHaveTextContent('Impossible de charger');
 expect(screen.getByRole('button',{name:'Réessayer'})).toBeInTheDocument();
});
test('Visiteur : aucun prix affiché même si une réponse en contient', async () => {
 listProducts.mockResolvedValue([{id:1,nom:'Disjoncteur',ref_fabricant:'00123',offres:[{id:1,fournisseur:'Rexel',prix:123.45,nature_prix:'demonstration'}]}]);
 render(<App />);fireEvent.click(screen.getByRole('button',{name:'Explorer le catalogue'}));
 expect(await screen.findByRole('heading',{name:'Disjoncteur'})).toBeInTheDocument();
 expect(screen.queryByText(/123,45/)).not.toBeInTheDocument();
});
test('Dashboard sans commandes fictives', () => {
 useAuth.mockReturnValue({user:{id:'a',nom:'Artisan',role:'artisan'},loading:false,logout:jest.fn()});
 render(<App />);fireEvent.click(screen.getByRole('button',{name:'Mes économies'}));
 expect(screen.getByText(/Aucune économie n’est affichée/)).toBeInTheDocument();
});
