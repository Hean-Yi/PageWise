import {build} from 'esbuild';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve} from 'node:path';
const root=resolve(import.meta.dirname,'../..'),out=resolve(root,'Sources/PaperReaderUI/Platform/HTML/NoteEditor/NoteEditor.bundle');
await mkdir(out,{recursive:true});
await build({entryPoints:[resolve(root,'Sources/PaperReaderUI/Platform/HTML/NoteEditor/Editor.js')],outfile:resolve(out,'editor.js'),bundle:true,minify:true,format:'iife',target:'safari18',nodePaths:[resolve(import.meta.dirname,'node_modules')],legalComments:'none'});
const lock=JSON.parse(await readFile(resolve(import.meta.dirname,'package-lock.json'),'utf8'));
let notices='PaperReader native Markdown editor. Build: npm ci && npm run build in scripts/note-editor.\n\n';
for(const [path,pkg] of Object.entries(lock.packages)){if(!path||pkg.dev||path.includes('esbuild'))continue;try{const license=await readFile(resolve(import.meta.dirname,path,'LICENSE'),'utf8');notices+=`${path.replace('node_modules/','')} ${pkg.version}\n${license}\n\n`;}catch{throw new Error('Missing license: '+path);}}
await writeFile(resolve(out,'LICENSES.txt'),notices.trimEnd()+'\n');
