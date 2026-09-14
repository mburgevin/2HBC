const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const app = path.resolve(__dirname, '..');
const src = path.resolve(app, '../extensions/2hbc');
const out = path.join(app, 'public/extension');
const shared = fs.readFileSync(path.join(app, 'src/lib/supplierTransfer.js'), 'utf8');
const names = [...shared.matchAll(/^export (?:const|function) (\w+)/gm)].map(m => m[1]);
if (!names.length) throw new Error('Shared protocol exports not found.');
const core = '(function(){\n' + shared.replace(/^export /gm, '') + '\nglobalThis.TwoHbc = Object.freeze({' + names.join(',') + '});\n})();\n';
new vm.Script(core);
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });
for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
  if (!entry.isFile()) throw new Error('Unexpected extension subdirectory: ' + entry.name);
  const content = fs.readFileSync(path.join(src, entry.name));
  if (entry.name.endsWith('.js')) new vm.Script(content.toString(), { filename: entry.name });
  fs.writeFileSync(path.join(out, entry.name), content);
}
fs.writeFileSync(path.join(out, 'core.js'), core);
const manifest = JSON.parse(fs.readFileSync(path.join(out,'manifest.json'),'utf8'));
if (manifest.manifest_version !== 3) throw new Error('Manifest V3 required.');
// ZIP STORE archive: no runtime/build dependency, and reproducible entry order.
const crcTable = Array.from({length:256}, (_,n) => {
  for(let i=0;i<8;i++) n = n & 1 ? 0xedb88320 ^ (n >>> 1) : n >>> 1;
  return n >>> 0;
});
function crc32(data) {
  let c = 0xffffffff;
  for (const b of data) c = crcTable[(c ^ b) & 255] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
const chunks=[], central=[]; let offset=0;
const entries=fs.readdirSync(out).sort();
for(const filename of entries) {
  const name=Buffer.from('extension-2hbc/' + filename), data=fs.readFileSync(path.join(out,filename)), crc=crc32(data);
  const local=Buffer.alloc(30);
  local.writeUInt32LE(0x04034b50,0); local.writeUInt16LE(20,4); local.writeUInt16LE(0x800,6);
  local.writeUInt16LE(33,12); local.writeUInt32LE(crc,14); local.writeUInt32LE(data.length,18); local.writeUInt32LE(data.length,22); local.writeUInt16LE(name.length,26);
  chunks.push(local,name,data);
  const c=Buffer.alloc(46);
  c.writeUInt32LE(0x02014b50,0); c.writeUInt16LE(20,4); c.writeUInt16LE(20,6); c.writeUInt16LE(0x800,8);
  c.writeUInt16LE(33,14); c.writeUInt32LE(crc,16); c.writeUInt32LE(data.length,20); c.writeUInt32LE(data.length,24);
  c.writeUInt16LE(name.length,28); c.writeUInt32LE(offset,42);
  central.push(c,name); offset+=local.length+name.length+data.length;
}
const directory=Buffer.concat(central), end=Buffer.alloc(22);
end.writeUInt32LE(0x06054b50,0); end.writeUInt16LE(entries.length,8); end.writeUInt16LE(entries.length,10);
end.writeUInt32LE(directory.length,12); end.writeUInt32LE(offset,16);
fs.writeFileSync(path.join(app,'public/extension-2hbc.zip'),Buffer.concat([...chunks,directory,end]));
console.log('Extension packaged and JavaScript syntax checked (' + entries.length + ' files).');
