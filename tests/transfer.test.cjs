const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { webcrypto } = require('node:crypto');
const dir = path.resolve(__dirname, '../projet-millions/public/extension');
function read(name) { return fs.readFileSync(path.join(dir, name), 'utf8'); }
const context = vm.createContext({ URL, crypto: webcrypto, console });
vm.runInContext(read('core.js'), context);
vm.runInContext(read('connectors.js'), context);
const C = context.TwoHbc;
const plain = value => JSON.parse(JSON.stringify(value));
function transfer(extra = {}) {
  const now = Date.now();
  return { version: 1, id: webcrypto.randomUUID(), supplier:'rexel', createdAt:now, expiresAt:now + 1800000,
    lines:[{ref:'00123',quantity:10},{ref:'00456',quantity:5}], ...extra };
}
const profile = { enabled:true, mode:'text', quickOrderUrl:'https://www.rexel.fr/frx/newQuickorder',
  cartUrl:'https://www.rexel.fr/frx/cart', delimiter:',', header:'', inputSelector:'#bulk',
  analyzeSelector:'#analyze', previewRows:'.preview .line',previewRef:'.ref',previewQty:'.qty',
  addSelector:'#add',successSelector:'#success',cartRows:'.cart .line',cartRef:'.ref',cartQty:'.qty',
  emptyCartSelector:'#empty',errorSelector:'#error' };
test('references stay strings, duplicates aggregate, no manufacturer fallback', () => {
  assert.deepEqual(plain(C.normalizeLines([{ref:'00123',quantity:3},{ref:'00123',quantity:7}])),[{ref:'00123',quantity:10}]);
  assert.throws(() => C.createTransfer('rexel',[{quantite:1,produits_fournisseurs:{fournisseurs:{nom:'Rexel'},produits:{ref_fabricant:'123'}}}]),/Référence/);
  assert.throws(() => C.createTransfer('rexel',[{quantite:1,produits_fournisseurs:{fournisseurs:{nom:'Sonepar'},ref_fournisseur:'123'}}]),/autre fournisseur/);
});
test('reject invalid quantities, CSV injection, huge and expired payloads', () => {
  for (const quantity of [0,-1,1.5,NaN,'5',10000]) assert.throws(() => C.normalizeLines([{ref:'123',quantity}]));
  for (const ref of ['=SUM(A1)','123\n456','a,b','@123',123]) assert.throws(() => C.normalizeLines([{ref,quantity:1}]));
  assert.throws(() => C.normalizeLines(Array.from({length:201},()=>({ref:'123',quantity:1}))));
  assert.throws(() => C.normalizeLines([{ref:'123',quantity:9999},{ref:'123',quantity:1}]));
  assert.throws(() => C.validateTransfer(transfer({ expiresAt:Date.now()-1 })),/expiré/);
  assert.throws(() => C.validateTransfer(transfer({ expiresAt:Date.now()+86400000 })),/expiré/);
});
test('only supplier HTTPS origin and non-checkout destinations are accepted', () => {
  assert.equal(C.supplierUrl('rexel','https://www.rexel.fr/frx/cart'),'https://www.rexel.fr/frx/cart');
  for (const url of ['https://www.rexel.fr.evil.test/cart','http://www.rexel.fr/cart',
    'https://user:pass@www.rexel.fr/cart','https://www.rexel.fr/checkout','javascript:alert(1)']) assert.equal(C.supplierUrl('rexel',url),null);
  assert.throws(() => C.validateOrigin('https://example.com'));
});
test('comparison respects existing cart, missing/excess lines and special object keys', () => {
  const lines=[{ref:'00123',quantity:10},{ref:'constructor',quantity:1}];
  const before={'00123':2}, after={'00123':12,constructor:1};
  assert.equal(C.reconcile(lines,before,after).state,'verified');
  assert.equal(C.reconcile(lines,before,{'00123':11,constructor:1}).lines[0].status,'missing');
  assert.equal(C.reconcile(lines,before,{'00123':22,constructor:1}).lines[0].status,'excess');
  assert.equal(C.reconcile(lines,null,after).state,'unverified');
  assert.equal(C.quickOrderText([{ref:'00123',quantity:10}]),'00123,10');
});
test('profile activation requires cart evidence and denies checkout', () => {
  assert.equal(context.TwoHbcConnectors.validateProfile('rexel',profile).enabled,true);
  assert.throws(() => context.TwoHbcConnectors.validateProfile('rexel',{...profile,cartUrl:'https://www.rexel.fr/checkout'}));
  assert.throws(() => context.TwoHbcConnectors.validateProfile('rexel',{...profile,emptyCartSelector:''}));
});
function runtime(state = { local:{profiles:{rexel:profile}}, session:{}, tabs:[], next:10 }) {
  let listener;
  const event = {addListener(){}};
  const area = name => ({
    async get(keys) { return Object.fromEntries((Array.isArray(keys)?keys:[keys]).map(k=>[k,structuredClone(state[name][k])])); },
    async set(obj) { Object.assign(state[name],structuredClone(obj)); },
    async setAccessLevel(){}
  });
  const chrome = {
    runtime:{ getURL:p=>'chrome-extension://test/'+p,onInstalled:event,onMessage:{addListener(fn){listener=fn;}}},
    storage:{local:area('local'),session:area('session')},
    alarms:{create(){},onAlarm:event},
    tabs:{onRemoved:event,async create(params){const t={id:state.next++,...params};state.tabs.push(t);return t;},
      async update(id,params){const t=state.tabs.find(x=>x.id===id);if(!t)throw Error('missing tab');Object.assign(t,params);return t;}},
    action:{async setBadgeText(){}}, permissions:{async contains(){return true;}},
    scripting:{async getRegisteredContentScripts(){return [];},async unregisterContentScripts(){},async registerContentScripts(){}}
  };
  const ctx=vm.createContext({URL,crypto:webcrypto,chrome,console,structuredClone});
  ctx.importScripts=(...names)=>names.forEach(n=>vm.runInContext(read(n),ctx,{filename:n}));
  vm.runInContext(read('background.js'),ctx);
  const app={url:'https://2-hbc.vercel.app/',frameId:0,tab:{id:1}};
  const control={url:'chrome-extension://test/popup.html'};
  function send(m,sender=app){return new Promise(resolve=>listener(m,sender,resolve));}
  return {state,send,app,control, supplier(t,url=profile.quickOrderUrl){return {url,frameId:0,tab:{id:t.supplierTab}};}};
}
test('origin and frame spoofing cannot start a transfer or change settings', async () => {
  const r=runtime();
  for(const sender of [{...r.app,url:'https://evil.vercel.app/'},{...r.app,frameId:1}]) {
    assert.equal((await r.send({kind:'APP',action:'START',payload:transfer()},sender)).ok,false);
  }
  assert.equal((await r.send({kind:'CONTROL',action:'SAVE_SETTINGS',profiles:{rexel:profile}},r.app)).ok,false);
  assert.equal(r.state.tabs.length,0);
});
test('simultaneous duplicate launch opens one tab and another supplier job is blocked',async()=>{
  const r=runtime(), payload=transfer();
  const replies=await Promise.all([r.send({kind:'APP',action:'START',payload}),r.send({kind:'APP',action:'START',payload})]);
  assert(replies.every(v=>v.ok));assert.equal(r.state.tabs.length,1);
  assert.equal(replies[0].result.id,replies[1].result.id);
  const second=await r.send({kind:'APP',action:'START',payload:transfer({lines:[{ref:'NEW',quantity:1}]})});
  assert.equal(second.ok,false);assert.equal(r.state.tabs.length,1);
});
test('claim survives worker restart, repeated add is refused and result verifies delta',async()=>{
  const r=runtime(), payload=transfer();
  await r.send({kind:'APP',action:'START',payload});
  let t=r.state.session.tasks[payload.id];
  assert.equal((await r.send({kind:'CONTROL',action:'RUN',id:t.id},r.control)).ok,true);
  t=r.state.session.tasks[t.id];
  assert.equal((await r.send({kind:'SUPPLIER',action:'BASELINE',id:t.id,snapshot:{'00123':2}},r.supplier(t,profile.cartUrl))).ok,true);
  await r.send({kind:'SUPPLIER',action:'CLAIM_PREPARE',id:t.id},r.supplier(t));
  await r.send({kind:'SUPPLIER',action:'PREPARED',id:t.id},r.supplier(t));
  const claimed=await r.send({kind:'SUPPLIER',action:'CLAIM_ADD',id:t.id,snapshot:{'00123':10,'00456':5}},r.supplier(t));
  assert.equal(claimed.result.state,'submitting');
  const restarted=runtime(r.state);
  assert.equal((await restarted.send({kind:'SUPPLIER',action:'CLAIM_ADD',id:t.id,snapshot:{'00123':10,'00456':5}},r.supplier(t))).ok,false);
  await restarted.send({kind:'SUPPLIER',action:'GET',id:t.id,login:false},r.supplier(t,profile.cartUrl));
  const verified=await restarted.send({kind:'SUPPLIER',action:'VERIFIED',id:t.id,snapshot:{'00123':12,'00456':5}},r.supplier(t,profile.cartUrl));
  assert.equal(verified.result.state,'verified');
  const again=await restarted.send({kind:'APP',action:'START',payload:transfer()});
  assert.equal(again.result.id,payload.id);assert.equal(r.state.tabs.length,1);
});
test('changed preview cannot claim an add and post-injection stop is indeterminate',async()=>{
  const r=runtime(), payload=transfer();
  await r.send({kind:'APP',action:'START',payload});const t=r.state.session.tasks[payload.id];
  await r.send({kind:'CONTROL',action:'RUN',id:t.id},r.control);
  await r.send({kind:'SUPPLIER',action:'BASELINE',id:t.id,snapshot:{}},r.supplier(t,profile.cartUrl));
  await r.send({kind:'SUPPLIER',action:'CLAIM_PREPARE',id:t.id},r.supplier(t));
  await r.send({kind:'SUPPLIER',action:'PREPARED',id:t.id},r.supplier(t));
  assert.equal((await r.send({kind:'SUPPLIER',action:'CLAIM_ADD',id:t.id,snapshot:{'00123':20,'00456':5}},r.supplier(t))).ok,false);
  const stop=await r.send({kind:'APP',action:'CANCEL',payload:{id:t.id}});
  assert.equal(stop.result.state,'indeterminate');
  assert.equal((await r.send({kind:'CONTROL',action:'RUN',id:t.id},r.control)).ok,false);
});
test('extension has no cookie/debugger access and bundle contains no remote executable code',()=>{
  const manifest=JSON.parse(read('manifest.json'));
  assert.equal(manifest.manifest_version,3);
  assert(!manifest.permissions.includes('cookies'));assert(!manifest.permissions.includes('debugger'));
  assert(!manifest.host_permissions.includes('<all_urls>'));
  assert(!read('background.js').includes('fetch('));
  for(const file of ['background.js','supplier.js','bridge.js','popup.js','options.js']) new vm.Script(read(file));
});
