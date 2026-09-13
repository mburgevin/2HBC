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
