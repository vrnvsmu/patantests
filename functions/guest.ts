import { Pool } from 'pg';
const pool = new Pool({connectionString: process.env.GUEST_DATABASE_URL, max: 3, connectionTimeoutMillis: 8000, statement_timeout: 15000});
const routes: Record<string, [string,string[]]> = {
 list_topics:['guest_topics',[]], get_question_topics:['guest_question_topics',['p_question_ids']], get_question_options:['guest_question_options',['p_question_ids']], get_public_content:['guest_public_content',['p_table']], get_public_turntable:['guest_turntable',['p_id']], start_attempt:['start_guest_attempt',['p_mode','p_topic_id','p_count','p_guest_token']], check_answer:['check_guest_answer',['p_attempt','p_question','p_option','p_guest_token']], finish_attempt:['finish_guest_attempt',['p_attempt','p_guest_token']], get_attempt_review:['get_guest_attempt_review',['p_attempt','p_guest_token']], resume_guest_attempt:['resume_guest_attempt',['p_attempt','p_guest_token']]
};
export default {async fetch(request: Request) {
 const origin=request.headers.get('origin'); const allowed=process.env.ALLOWED_ORIGIN || 'https://vrnvsmu.github.io';
 const headers={'Content-Type':'application/json','Access-Control-Allow-Origin':allowed,'Access-Control-Allow-Methods':'POST, OPTIONS','Access-Control-Allow-Headers':'Content-Type','Vary':'Origin','Cache-Control':'no-store'};
 const reply=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers});
 if(origin && origin!==allowed)return reply({error:{message:'Origin denied'}},403);
 if(request.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(request.method!=='POST')return reply({error:{message:'Method not allowed'}},405);
 if(!process.env.GUEST_DATABASE_URL)return reply({error:{message:'Guest service is not configured'}},503);
 try {
  const raw=await request.text(); if(raw.length>65536)return reply({error:{message:'Request too large'}},413);
  const {name,args={}}=JSON.parse(raw); if(typeof name!=='string'||!Object.hasOwn(routes,name)||!args||typeof args!=='object')return reply({error:{message:'Unknown operation'}},400);
  const [fn,keys]=routes[name]; const values=keys.map(k=>args[k]??null);
  if(keys.includes('p_guest_token')&&!/^[a-f0-9]{64}$/.test(args.p_guest_token||''))return reply({error:{message:'Invalid guest session'}},400);
  const result=await pool.query(`SELECT public.${fn}(${keys.map((_,i)=>'$'+(i+1)).join(',')}) AS data`,values);
  return reply({data:result.rows[0].data,error:null});
 }catch(e){console.error('guest request failed',e);return reply({error:{message:'Гостевой запрос не выполнен. Проверьте параметры или повторите позже.'}},400);}
}};
