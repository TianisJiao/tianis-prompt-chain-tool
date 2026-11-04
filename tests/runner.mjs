import assert from 'node:assert/strict';
import {executeStep} from '../lib/runner.mjs';
import {validateDraft,stepInput} from '../lib/studio.mjs';
let calls=[];const fetcher=async(u,r)=>{calls.push(JSON.parse(r.body));return {ok:true,json:async()=>({status:'completed',id:'resp_test',usage:{input_tokens:10,output_tokens:5},output:[{content:[{type:'output_text',text:'Generated '+calls.length}]}]})}};
const step={name:'Test',model:'test-model',instructions:'Use the input.',input_kind:'previous'};
let previous=null;for(let n=0;n<3;n++){const e=await executeStep({step,initial:'Original',previous,apiKey:'placeholder',fetcher});assert.equal(e.status,'succeeded');assert.equal(e.input_tokens,10);assert.equal(e.output_tokens,5);assert.equal(e.input_text,n?previous:'Original');assert.ok(!JSON.stringify(e).includes('placeholder'));previous=e.output_text}
assert.equal(calls[1].input[0].content[0].text,'Generated 1');assert.equal(calls[2].input[0].content[0].text,'Generated 2');
assert.equal(stepInput({...step,input_kind:'original'},'Original','Later'),'Original');
const image=await executeStep({step:{...step,input_kind:'image'},initial:'Describe',previous:'Angle',imageData:'data:image/png;base64,abc',apiKey:'placeholder',fetcher});assert.equal(calls.at(-1).input[0].content[1].type,'input_image');assert.equal(image.image_attached,true);assert.ok(!JSON.stringify(image).includes('data:image'));assert.equal(calls.at(-1).store,false);
await assert.rejects(()=>executeStep({step:{...step,input_kind:'image'},apiKey:'placeholder',fetcher}));
for(const code of [401,429,500]){const e=await executeStep({step,initial:'x',apiKey:'placeholder',fetcher:async()=>({ok:false,status:code})});assert.equal(e.status,'failed');assert.ok(e.error_code)}
const no=await executeStep({step,initial:'x',apiKey:'x',fetcher:async()=>({ok:true,json:async()=>({status:'incomplete',output:[]})})});assert.equal(no.error_code,'invalid_model_output');
assert.throws(()=>validateDraft({name:'x',description:'',steps:[{}]}));assert.throws(()=>validateDraft({name:'',description:'',steps:[]}));validateDraft({name:'Draft',description:'',steps:[]});
console.log('PASS: real runner supports variable step sequences, previous/original/image inputs, metadata without image bytes or secrets, provider errors, incomplete output, draft validation. Provider mocked.');
