const { test, expect, chromium } = require('@playwright/test');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const appOrigin='https://2-hbc.vercel.app';
const suppliers={rexel:'https://www.rexel.fr',sonepar:'https://www.sonepar.fr'};
const extensionPath=path.resolve(__dirname,'../../projet-millions/public/extension');
function profile(id, mode='text', override={}) {
 const origin=suppliers[id];
 return {enabled:true,mode,quickOrderUrl:origin+(id==='rexel'?'/frx/newQuickorder':'/fr-fr/test-quick-order'),
  cartUrl:origin+'/test-cart',delimiter:',',header:'',inputSelector:'#bulk',
  analyzeSelector:mode==='text'?'#analyze':'',previewRows:'.preview .line',previewRef:'.ref',previewQty:'.qty',
  addSelector:'#add',successSelector:'#success',cartRows:'.cart .line',cartRef:'.ref',cartQty:'.qty',
  emptyCartSelector:'#empty',errorSelector:'#error',...override};
}
function fixture(url,{mode='text',login=false,clamp=false,badPrice=false}) {
 const u=new URL(url);
 if(u.pathname.includes('/p/') || u.pathname.includes('/products/')) return '<h1>Fiche prix simulée</h1>' +
  '<span id="account">Compte fictif A</span><span id="context">Agence Nantes - aucune affaire</span>' +
  '<span id="ref">LEG069511L</span><span id="kind">Prix net</span><span id="tax">'+(badPrice?'TTC':'HT')+'</span>' +
  '<input id="quantity" value="10"><span id="unit">unité</span><span id="currency">EUR</span>' +
  '<span id="price">1 234,56 €</span><span id="basis">100</span><button id="order" onclick="localStorage.orders=1">Commander</button>';

 if(u.pathname==='/login') return '<h1>Connexion simulée</h1><input type="password" aria-label="Mot de passe de test"><button id="login">Se connecter</button><script>document.getElementById("login").onclick=()=>{sessionStorage.logged="1";location.href="/test-cart"};</script>';
 function cartScript(needsLogin) {
  if(needsLogin&&!sessionStorage.logged) location.replace('/login');
  const cart=JSON.parse(localStorage.cart||'{"00123":2,"OTHER":1}');
  for(const [ref,qty] of Object.entries(cart)){
   const row=document.createElement('div');row.className='line';
   const r=document.createElement('span');r.className='ref';r.textContent=ref;
   const q=document.createElement('input');q.className='qty';q.value=qty;
   row.append(r,q);document.querySelector('.cart').append(row);
  }
  document.getElementById('empty').hidden=Object.keys(cart).length>0;
  document.getElementById('order').onclick=()=>localStorage.orders=Number(localStorage.orders||0)+1;
 }
 if(u.pathname==='/test-cart') return '<h1>Panier simulé</h1><div class="cart"></div><div id="empty" hidden>Panier vide</div><button id="order">Commander</button><script>('
  +cartScript.toString()+')('+JSON.stringify(login)+');</script>';
 function quickScript(adjust) {
  let lines=[];
  function parse(text){
   lines=text.replace(/^\uFEFF/,'').trim().split(/\r?\n/).map(l=>{const [ref,q]=l.split(',');return {ref,quantity:adjust?Number(q)+1:Number(q)};});
   document.querySelector('.preview').replaceChildren();
   for(const line of lines){
    const row=document.createElement('div');row.className='line';
    const ref=document.createElement('span');ref.className='ref';ref.textContent=line.ref;
    const qty=document.createElement('input');qty.className='qty';qty.value=line.quantity;
    row.append(ref,qty);document.querySelector('.preview').append(row);
   }
  }
  const field=document.getElementById('bulk');
  if(field.type==='file')field.onchange=async()=>parse(await field.files[0].text());
  else document.getElementById('analyze').onclick=()=>parse(field.value);
  document.getElementById('add').onclick=()=>{
   localStorage.adds=Number(localStorage.adds||0)+1;
   setTimeout(()=>{
    const cart=JSON.parse(localStorage.cart||'{"00123":2,"OTHER":1}');
    for(const l of lines)cart[l.ref]=(cart[l.ref]||0)+l.quantity;
    localStorage.cart=JSON.stringify(cart);document.getElementById('success').hidden=false;
   },250);
  };
  document.getElementById('order').onclick=()=>localStorage.orders=Number(localStorage.orders||0)+1;
 }
 const field=mode==='file'?'<input id="bulk" type="file" accept=".csv">':'<textarea id="bulk"></textarea><button id="analyze">Analyser les références</button>';
 return '<h1>Commande rapide simulée</h1>'+field+'<div class="preview"></div><button id="add">Ajouter au panier</button><p id="success" hidden>Produits ajoutés</p><p id="error" hidden>Erreur</p><button id="order">Valider la commande</button><script>('
  +quickScript.toString()+')('+JSON.stringify(clamp)+');</script>';
}
async function launch(options={}) {
 const temp=await fs.mkdtemp(path.join(os.tmpdir(),'2hbc-extension-'));
 const context=await chromium.launchPersistentContext(temp,{
  channel:'chromium',headless:true,args:['--disable-extensions-except='+extensionPath,'--load-extension='+extensionPath]
 });
 // Supplier/app documents are synthetic. No real supplier network request is allowed.
 await context.route('https://**/*',async route=>{
  const url=new URL(route.request().url());
  if(url.origin===appOrigin) return route.fulfill({contentType:'text/html; charset=utf-8',body:'<!doctype html><html lang="fr"><title>2HBC fixture</title><h1>2HBC — test isolé</h1></html>'});
  const supplier=Object.keys(suppliers).find(k=>suppliers[k]===url.origin);
  if(supplier)return route.fulfill({contentType:'text/html; charset=utf-8',body:fixture(url.href,{...options,supplier})});
  return route.abort();
 });
 let worker=context.serviceWorkers()[0];
 if(!worker)worker=await context.waitForEvent('serviceworker');
 const id=new URL(worker.url()).host;
 const optionsPage=await context.newPage();await optionsPage.goto('chrome-extension://'+id+'/options.html');
 await expect.poll(()=>optionsPage.locator('#rexel').inputValue()).toContain('"enabled"');
 await optionsPage.locator('#rexel').fill(JSON.stringify(profile('rexel',options.mode||'text',options.profileOverride)));
 await optionsPage.locator('#sonepar').fill(JSON.stringify(profile('sonepar',options.mode||'text',options.profileOverride)));
 await optionsPage.getByRole('button',{name:'Enregistrer les réglages'}).click();
 await expect(optionsPage.getByRole('status')).toContainText('Réglages enregistrés');
 const app=await context.newPage();await app.goto(appOrigin);
 await app.waitForTimeout(300);
 async function request(action,payload) {
  return app.evaluate(({action,payload})=>new Promise((resolve,reject)=>{
   const requestId=crypto.randomUUID(),timer=setTimeout(()=>{window.removeEventListener('message',receive);reject(Error('bridge timeout'));},5000);
   function receive(event){const m=event.data;if(event.source===window&&event.origin===location.origin&&m?.channel==='2HBC_AUTO_CART_V1'&&m.direction==='extension'&&m.requestId===requestId){clearTimeout(timer);window.removeEventListener('message',receive);resolve(m);}}
   window.addEventListener('message',receive);window.postMessage({channel:'2HBC_AUTO_CART_V1',direction:'app',requestId,action,payload},location.origin);
  }),{action,payload});
 }
 await expect.poll(async()=>{try{return (await request('PING')).ok;}catch{return false;}}).toBe(true);
 const popup=await context.newPage();await popup.goto('chrome-extension://'+id+'/popup.html');
 async function run(supplier='rexel') {
  const now=Date.now(),transfer={version:1,id:require('node:crypto').randomUUID(),supplier,createdAt:now,expiresAt:now+1800000,
   lines:[{ref:'00123',quantity:10},{ref:'00456',quantity:5}]};
  const response=await request('START',transfer);expect(response.ok).toBe(true);
  await popup.reload();await popup.getByRole('checkbox').check();
  await popup.getByRole('button',{name:'Préparer automatiquement le panier'}).click();
  return {transfer,status:async()=>{const reply=await request('STATUS',{id:transfer.id});return reply.result;}};
 }
 return {context,app,popup,request,run,async close(){await context.close();await fs.rm(temp,{recursive:true,force:true});}};
}
test('Rexel text lot: login resume, existing quantities preserved, no order and no duplicate',async()=>{
 const h=await launch({login:true});
 try{
  const job=await h.run('rexel');
  await expect.poll(async()=>(await job.status()).state).toBe('awaiting_login');
  const supplierPage=h.context.pages().find(p=>p.url().startsWith(suppliers.rexel));
  await supplierPage.getByLabel('Mot de passe de test').fill('fixture-only');
  await supplierPage.getByRole('button',{name:'Se connecter',exact:true}).click();
  await expect.poll(async()=>(await job.status()).state,{timeout:30000}).toBe('verified');
  expect(await supplierPage.evaluate(()=>JSON.parse(localStorage.cart))).toEqual({'00123':12,'00456':5,OTHER:1});
  expect(await supplierPage.evaluate(()=>localStorage.getItem('adds'))).toBe('1');
  expect(await supplierPage.evaluate(()=>localStorage.getItem('orders'))).toBeNull();
  const repeat=await h.request('START',{...job.transfer,id:require('node:crypto').randomUUID()});
  expect(repeat.result.id).toBe(job.transfer.id);
  expect(await supplierPage.evaluate(()=>localStorage.getItem('adds'))).toBe('1');
 }finally{await h.close();}
});
test('Sonepar in-memory CSV follows the same bulk flow without a file picker',async()=>{
 const h=await launch({mode:'file'});
 try{
  const job=await h.run('sonepar');
  await expect.poll(async()=>(await job.status()).state,{timeout:30000}).toBe('verified');
  const supplierPage=h.context.pages().find(p=>p.url().startsWith(suppliers.sonepar));
  expect(await supplierPage.evaluate(()=>JSON.parse(localStorage.cart)['00123'])).toBe(12);
  expect(await supplierPage.evaluate(()=>localStorage.getItem('adds'))).toBe('1');
  expect(await supplierPage.evaluate(()=>localStorage.getItem('orders'))).toBeNull();
 }finally{await h.close();}
});
test('quantity adjusted by supplier blocks add instead of silently accepting it',async()=>{
 const h=await launch({clamp:true});
 try{
  const job=await h.run();
  await expect.poll(async()=>(await job.status()).state).toBe('indeterminate');
  const page=h.context.pages().find(p=>p.url().startsWith(suppliers.rexel));
  expect(await page.evaluate(()=>localStorage.getItem('adds'))).toBeNull();
  expect((await job.status()).detail).toContain('diffère');
 }finally{await h.close();}
});
test('a configured checkout button is rejected even with an exact preview',async()=>{
 const h=await launch({profileOverride:{addSelector:'#order'}});
 try{
  const job=await h.run();
  await expect.poll(async()=>(await job.status()).state).toBe('indeterminate');
  const page=h.context.pages().find(p=>p.url().startsWith(suppliers.rexel));
  expect(await page.evaluate(()=>localStorage.getItem('orders'))).toBeNull();
  expect(await page.evaluate(()=>localStorage.getItem('adds'))).toBeNull();
  expect((await job.status()).detail).toContain('engager une commande');
 }finally{await h.close();}
});

const priceSelectors={enabled:true,accountSelector:'#account',contextSelector:'#context',refSelector:'#ref',kindSelector:'#kind',
 taxSelector:'#tax',quantitySelector:'#quantity',unitSelector:'#unit',currencySelector:'#currency',priceSelector:'#price',basisSelector:'#basis'};
function quoteRequest(){return {id:require('node:crypto').randomUUID(),sessionId:require('node:crypto').randomUUID(),
 userId:'11111111-1111-4111-8111-111111111111',offerId:1,supplier:'rexel',ref:'LEG069511L',quantity:10,
 url:'https://www.rexel.fr/frx/test-product/p/73224603'};}
test('personal price: native product page read, decimal and basis preserved, no account secret returned',async()=>{
 const h=await launch({profileOverride:{price:priceSelectors}});
 try {
  const request=quoteRequest();expect((await h.request('PRICE_START',request)).ok).toBe(true);
  await expect.poll(async()=>(await h.request('PRICE_STATUS',request)).result?.state).toBe('observed');
  const result=(await h.request('PRICE_STATUS',request)).result.quote;
  expect(result).toMatchObject({amount:1234.56,basis:100,quantity:10,tax:'HT',unit:'piece'});
  expect(result.contextKey).toMatch(/^[a-f0-9]{64}$/);
  expect(JSON.stringify(result)).not.toContain('Compte fictif');
  expect(JSON.stringify(result)).not.toContain('Agence Nantes');
  expect((await h.request('PRICE_STATUS',{...request,userId:'22222222-2222-4222-8222-222222222222'})).ok).toBe(false);
  const page=h.context.pages().find(p=>p.url()===request.url);
  expect(await page.evaluate(()=>localStorage.getItem('orders'))).toBeNull();
 } finally {await h.close();}
});
test('TTC is never accepted as personal HT; the user can cancel the pending read',async()=>{
 const h=await launch({badPrice:true,profileOverride:{price:priceSelectors}});
 try {
  const request=quoteRequest();expect((await h.request('PRICE_START',request)).ok).toBe(true);
  await expect.poll(()=>h.context.pages().some(p=>p.url()===request.url)).toBe(true);
  const page=h.context.pages().find(p=>p.url()===request.url);
  await page.waitForTimeout(4000);
  expect((await h.request('PRICE_STATUS',request)).result).toMatchObject({state:'reading',quote:null});
  expect((await h.request('PRICE_CANCEL',request)).result.state).toBe('cancelled');
 } finally {await h.close();}
});
