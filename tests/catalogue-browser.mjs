// Local browser → intercepted RPC transport → real PostgreSQL (PGlite) → UI.
// No live Supabase writes, real customer sessions, or supplier requests.
import {createServer} from 'node:http';import {readFile,readdir,mkdir} from 'node:fs/promises';import {resolve,extname} from 'node:path';
import {PGlite} from '@electric-sql/pglite';import {createRequire} from 'node:module';const {chromium}=createRequire(import.meta.url)('playwright');import assert from 'node:assert/strict';
const db=new PGlite();let browser,server;
try{
 await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select null::uuid$$;create function auth.jwt() returns jsonb language sql stable as $$select '{}'::jsonb$$;grant usage on schema auth to anon,authenticated;`);
 for(const f of (await readdir('supabase/migrations')).sort())await db.exec(await readFile('supabase/migrations/'+f,'utf8'));
 const products=JSON.parse(await readFile('catalog/validation/20261016/products-pending.json','utf8'));
 for(const p of products)await db.query('select importer_catalogue_v2($1,true)',[JSON.stringify({...p,review_status:'approved'})]);
 await db.exec('set role anon');
 const build=resolve('projet-millions/build');
 server=createServer(async(req,res)=>{try{let path=resolve(build,'.'+new URL(req.url,'http://localhost').pathname);if(!path.startsWith(build+'/'))path=build+'/index.html';const data=await readFile(path);res.setHeader('Content-Type',({'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.svg':'image/svg+xml'})[extname(path)]||'application/octet-stream');res.end(data);}catch{res.writeHead(404);res.end();}});
 await new Promise(r=>server.listen(4173,'127.0.0.1',r));
 browser=await chromium.launch({headless:true,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || chromium.executablePath(),args:['--no-sandbox']});const page=await browser.newPage({viewport:{width:1280,height:900}});const errors=[],requests=[];
 page.on('pageerror',e=>errors.push(e.message));
 await page.route('https://**',async route=>{
  if(route.request().url().includes('/rest/v1/rpc/rechercher_catalogue_v2')){
   const request=route.request().postDataJSON();requests.push(request);
   try{const result=(await db.query('select rechercher_catalogue_v2($1,$2,$3) result',[request.terme,JSON.stringify(request.filtres),request.page_num])).rows[0].result;
    await route.fulfill({status:200,contentType:'application/json',headers:{'access-control-allow-origin':'*'},body:JSON.stringify(result)});
   }catch(e){await route.fulfill({status:400,contentType:'application/json',body:JSON.stringify({message:e.message})});}
  }else await route.abort();
 });
 await page.goto('http://127.0.0.1:4173');await page.getByRole('button',{name:'Explorer le catalogue'}).click();
 await page.getByText('3 produits trouvés',{exact:true}).waitFor();
 await page.getByLabel('Catégorie',{exact:true}).selectOption('disjoncteurs');await page.getByText('1 produit trouvé',{exact:true}).waitFor();
 assert.equal(requests.at(-1).filtres.categorie[0],'disjoncteurs');
 await page.getByRole('button',{name:'Voir le produit',exact:true}).click();await page.getByRole('heading',{name:'Caractéristiques techniques'}).waitFor();
 assert.match(await page.getByRole('dialog').innerText(),/10 A/);assert.match(await page.getByRole('dialog').innerText(),/4.5 kA/);
 await page.getByRole('button',{name:'Fermer',exact:true}).click();await page.getByRole('button',{name:'Tout effacer'}).click();await page.getByText('3 produits trouvés',{exact:true}).waitFor();
 const input=page.getByLabel('Rechercher par nom, marque, EAN ou référence fournisseur');await input.fill('01887138132');await input.press('Enter');await page.getByText('1 produit trouvé',{exact:true}).waitFor();
 assert.equal(requests.at(-1).terme,'01887138132');
 await input.fill('');await input.press('Enter');await page.getByText('3 produits trouvés',{exact:true}).waitFor();
 await mkdir('test-results',{recursive:true});await page.screenshot({path:'test-results/catalogue-desktop.png',fullPage:true});
 await page.setViewportSize({width:390,height:844});await page.screenshot({path:'test-results/catalogue-mobile.png',fullPage:true});
 assert(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth));assert.deepEqual(errors,[]);
 console.log(JSON.stringify({status:'passed',products:products.length,rpc_requests:requests.length,checks:['category','numeric specifications','supplier SKU search','clear filters','mobile no horizontal overflow','no JavaScript errors'],transport:'local RPC bridge to PGlite, not live Supabase'}));
}finally{if(browser)await browser.close();if(server)await new Promise(r=>server.close(r));await db.close();}
