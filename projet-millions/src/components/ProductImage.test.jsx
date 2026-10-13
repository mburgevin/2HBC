import React from 'react';
import { render, screen, fireEvent } from '@testing-library/react';
import ProductImage from './ProductImage';
jest.mock('../lib/supabase',()=>({getSupabase:jest.fn()}));

test('une photo cassée affiche un remplacement ; une nouvelle URL peut charger',()=>{
 const product={nom:'Interrupteur gris',image_url:'https://api.rexel.fr/media/api/fr/content/123/EXTRA_LARGE'};
 const {rerender}=render(<ProductImage product={product}/>);
 const photo=screen.getByRole('img',{name:product.nom});
 expect(photo).toHaveAttribute('referrerpolicy','no-referrer');
 fireEvent.error(photo);
 expect(screen.queryByRole('img')).not.toBeInTheDocument();
 expect(screen.getByText('Visuel à venir')).toBeInTheDocument();
 rerender(<ProductImage product={{...product,image_url:'https://api.rexel.fr/media/api/fr/content/456/EXTRA_LARGE'}}/>);
 expect(screen.getByRole('img',{name:product.nom})).toBeInTheDocument();
});
