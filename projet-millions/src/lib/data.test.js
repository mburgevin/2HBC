import { csvCell,cartCsv,safeUrl } from './data';
jest.mock('./supabase',()=>({getSupabase:jest.fn()}));
test('CSV : séparateurs, guillemets et formules',()=>{
 expect(csvCell('a;"b"')).toBe('"a;""b"""');
 expect(csvCell('=1+1')).toBe('"\'=1+1"');
 expect(csvCell('00123')).toBe('"00123"');expect(cartCsv([])).toMatch(/^\uFEFF/);
});
test('Liens HTTPS seulement',()=>{
 expect(safeUrl('javascript:alert(1)')).toBeNull();expect(safeUrl('http://example.com')).toBeNull();
 expect(safeUrl('https://www.rexel.fr/test')).toBe('https://www.rexel.fr/test');
});

test('Recherche v2 : repli uniquement si RPC absente et aucun filtre actif', async () => {
 const {getSupabase}=require('./supabase');const {searchCatalogue}=require('./data');
 const rpc=jest.fn().mockResolvedValueOnce({error:{code:'PGRST202'}}).mockResolvedValueOnce({data:[]});getSupabase.mockReturnValue({rpc});
 expect(await searchCatalogue('prise',{},0)).toMatchObject({legacy:true,items:[]});
 expect(rpc.mock.calls[1][0]).toBe('rechercher_catalogue_personnel');
 rpc.mockReset().mockResolvedValue({error:{code:'PGRST202'}});
 await expect(searchCatalogue('',{'a:couleur':['blanc']},0)).rejects.toMatchObject({code:'PGRST202'});expect(rpc).toHaveBeenCalledTimes(1);
 rpc.mockReset().mockResolvedValue({error:{code:'42501'}});
 await expect(searchCatalogue()).rejects.toMatchObject({code:'42501'});expect(rpc).toHaveBeenCalledTimes(1);
});
