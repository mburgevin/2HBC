import {render,screen,fireEvent,waitFor} from '@testing-library/react';
import Catalogue from './Catalogue';
import {searchCatalogue} from '../lib/data';
jest.mock('./AuthContext',()=>({useAuth:()=>({user:null,loading:false})}));
jest.mock('../lib/data',()=>({...jest.requireActual('../lib/data'),searchCatalogue:jest.fn()}));
jest.mock('../lib/supabase',()=>({getSupabase:jest.fn()}));
const result={items:[],total:0,categories:[{id:1,code:'appareillage',nom:'Appareillage',parent_id:null},{id:2,code:'prises',nom:'Prises',parent_id:1}],facets:[{key:'a:couleur',label:'Couleur',type:'text',values:[{value:'blanc',label:'blanc',count:10},{value:'noir',label:'noir',count:2}]}]};
beforeEach(()=>{searchCatalogue.mockReset().mockResolvedValue(result);});
test('Filtre envoyé au serveur, remise à la page 0 et effacement',async()=>{
 render(<Catalogue onLoginClick={()=>{}}/>);
 fireEvent.click(await screen.findByLabelText(/blanc/));
 await waitFor(()=>expect(searchCatalogue).toHaveBeenLastCalledWith('',{'a:couleur':['blanc']},0));
 fireEvent.click(await screen.findByRole('button',{name:'Tout effacer'}));
 await waitFor(()=>expect(searchCatalogue).toHaveBeenLastCalledWith('',{},0));
});
test('Choix de catégorie, nombre total et pagination exacte',async()=>{
 searchCatalogue.mockResolvedValue({...result,total:24,items:Array.from({length:24},(_,i)=>({id:i,nom:'Produit '+i,ref_fabricant:'R'+i,offres:[]}))});
 render(<Catalogue onLoginClick={()=>{}}/>);
 expect(await screen.findByText('24 produits trouvés')).toBeInTheDocument();
 expect(screen.getByRole('button',{name:'Suivant'})).toBeDisabled();
 fireEvent.change(screen.getByLabelText('Catégorie'),{target:{value:'prises'}});
 await waitFor(()=>expect(searchCatalogue).toHaveBeenLastCalledWith('',{categorie:['prises']},0));
});
test('Une réponse ancienne ne remplace pas une recherche plus récente',async()=>{
 let resolveOld;searchCatalogue.mockImplementationOnce(()=>new Promise(resolve=>{resolveOld=resolve;})).mockResolvedValue({...result,total:1,items:[{id:2,nom:'Résultat récent',ref_fabricant:'R2'}]});
 render(<Catalogue onLoginClick={()=>{}}/>);
 fireEvent.change(screen.getByRole('textbox'),{target:{value:'recent'}});fireEvent.click(screen.getByRole('button',{name:'Rechercher'}));
 expect(await screen.findByText('Résultat récent')).toBeInTheDocument();
 resolveOld({...result,total:1,items:[{id:1,nom:'Ancien résultat',ref_fabricant:'R1'}]});
 await waitFor(()=>expect(screen.queryByText('Ancien résultat')).not.toBeInTheDocument());
});
