import React from 'react';
import { render, screen, within, fireEvent, waitFor } from '@testing-library/react';
import Panier from './Panier';
import { listCart, updateQuantity } from '../lib/data';
import { extensionRequest } from '../lib/autoCart';
jest.mock('./AuthContext',()=>({useAuth:()=>({user:{id:'artisan-test'},loading:false})}));
jest.mock('../lib/autoCart',()=>({extensionRequest:jest.fn()}));
jest.mock('../lib/data',()=>({...jest.requireActual('../lib/data'),listCart:jest.fn(),updateQuantity:jest.fn(),removeCartItem:jest.fn()}));
jest.mock('../lib/supabase',()=>({getSupabase:jest.fn()}));
const item=(id,name,ref)=>({id,quantite:1,produits_fournisseurs:{ref_fournisseur:ref,prix:10,nature_prix:'demonstration',
 fournisseurs:{nom:name},produits:{nom:'Produit '+id,ref_fabricant:'FAB-'+id}}});
beforeEach(()=>{
 jest.clearAllMocks();
 extensionRequest.mockResolvedValue({version:'0.1.0',suppliers:{rexel:true,sonepar:true}});
 Object.defineProperty(window.crypto,'randomUUID',{configurable:true,value:()=> 'transfer-test-00000000001'});
});
test('groups by supplier and enables only references explicitly provided',async()=>{
 listCart.mockResolvedValue([item(1,'Rexel',null),item(2,'Sonepar','00456')]);
 render(<Panier/>);
 const rexel=await screen.findByRole('region',{name:'Panier Rexel'});
 const sonepar=screen.getByRole('region',{name:'Panier Sonepar'});
 expect(within(rexel).getByText('Produit 1')).toBeInTheDocument();
 expect(within(rexel).queryByText('Produit 2')).not.toBeInTheDocument();
 expect(within(rexel).getByRole('button',{name:'Préparer mon panier Rexel'})).toBeDisabled();
 fireEvent.change(within(rexel).getByLabelText('Référence Rexel de Produit 1'),{target:{value:'00123'}});
 expect(within(rexel).getByRole('button',{name:'Préparer mon panier Rexel'})).toBeEnabled();
 expect(within(sonepar).getByRole('button',{name:'Préparer mon panier Sonepar'})).toBeEnabled();
});
test('unsaved quantity blocks transfer and save persists the entered quantity',async()=>{
 let data=[item(1,'Rexel','00123')];
 listCart.mockImplementation(async()=>data);
 updateQuantity.mockImplementation(async(id,qty)=>{data=[{...data[0],quantite:qty}];});
 render(<Panier/>);
 const field=await screen.findByLabelText('Quantité de Produit 1');
 fireEvent.change(field,{target:{value:'25'}});
 expect(screen.getByRole('button',{name:'Préparer mon panier Rexel'})).toBeDisabled();
 fireEvent.submit(field.closest('form'));
 await waitFor(()=>expect(updateQuantity).toHaveBeenCalledWith(1,25));
 await waitFor(()=>expect(screen.getByRole('button',{name:'Préparer mon panier Rexel'})).toBeEnabled());
 expect(screen.getByLabelText('Quantité de Produit 1')).toHaveValue('25');
});
test('invalid quantity does not mutate the cart',async()=>{
 listCart.mockResolvedValue([item(1,'Rexel','00123')]);render(<Panier/>);
 const field=await screen.findByLabelText('Quantité de Produit 1');
 fireEvent.change(field,{target:{value:'0'}});fireEvent.submit(field.closest('form'));
 expect(await screen.findByRole('alert')).toHaveTextContent('entier de 1 à 9999');
 expect(updateQuantity).not.toHaveBeenCalled();
});
test('transfer contains only selected supplier references and quantities',async()=>{
 listCart.mockResolvedValue([item(1,'Rexel','00123'),item(2,'Sonepar','00456')]);
 extensionRequest.mockImplementation(async(action,payload)=>action==='START'
  ? {id:payload.id,state:'awaiting_confirmation',message:'Confirmez le compte'}
  : {suppliers:{rexel:true,sonepar:true}});
 render(<Panier/>);
 fireEvent.click(await screen.findByRole('button',{name:'Préparer mon panier Rexel'}));
 await waitFor(()=>expect(extensionRequest).toHaveBeenCalledWith('START',expect.objectContaining({
   supplier:'rexel',lines:[{ref:'00123',quantity:1}]
 }),12000));
});
