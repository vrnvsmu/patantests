import { createRemoteJWKSet, jwtVerify } from "jose";
import { Pool } from "pg";
import { S3Client, PutObjectCommand, DeleteObjectCommand } from "@aws-sdk/client-s3";

const required=(name:string):string=>{const value=process.env[name];if(!value)throw new Error(`Missing required environment variable: ${name}`);return value;};
const bucket=required("TIMEWEB_S3_BUCKET");
const accessKeyId=required("TIMEWEB_S3_ACCESS_KEY");
const secretAccessKey=required("TIMEWEB_S3_SECRET_KEY");
const endpoint=process.env.TIMEWEB_S3_ENDPOINT||"https://s3.twcstorage.ru";
const region=process.env.TIMEWEB_S3_REGION||"ru-1";
const allowedOrigins=new Set(required("ALLOWED_ORIGIN").split(",").map(x=>x.trim()).filter(Boolean));
const databaseUrl=required("DATABASE_URL");
const authBaseUrl=required("NEON_AUTH_BASE_URL");
const jwksUrl=required("NEON_AUTH_JWKS_URL");
const pool=new Pool({connectionString:databaseUrl,max:5,idleTimeoutMillis:30_000,connectionTimeoutMillis:10_000});
const jwks=createRemoteJWKSet(new URL(jwksUrl));
const issuer=new URL(authBaseUrl).origin;
const s3=new S3Client({region,endpoint,forcePathStyle:true,credentials:{accessKeyId,secretAccessKey}});

function corsHeaders(origin:string):Record<string,string>{return {
  "Access-Control-Allow-Origin":origin&&allowedOrigins.has(origin)?origin:(allowedOrigins.values().next().value||"null"),
  "Access-Control-Allow-Headers":"authorization, content-type, x-object-key",
  "Access-Control-Allow-Methods":"POST, DELETE, OPTIONS",
  "Access-Control-Max-Age":"86400","Vary":"Origin"
};}
function checkedKey(value:unknown):string{
  const key=String(value??"").replace(/^\/+/,"").replace(/\\/g,"/");
  const parts=key.split("/");
  if(parts.some(p=>!p||p==='.'||p==='..')||key.includes('..')||!parts.every(p=>/^[A-Za-z0-9._-]+$/.test(p)))throw new Error("Недопустимый путь файла.");
  const turntable=/^turntables\/[0-9a-f-]{36}\/[A-Za-z0-9._-]+$/i.test(key);
  const media=/^testpatan-media\/[A-Za-z0-9._/-]+$/i.test(key);
  const material=/^testpatan-materials\/neon\/materials\/[A-Za-z0-9._-]+$/i.test(key);
  if(!turntable&&!media&&!material)throw new Error("Недопустимый путь файла.");
  return key;
}
async function requireAdmin(request:Request):Promise<string>{
  const authorization=request.headers.get("authorization")??"";
  if(!authorization.toLowerCase().startsWith("bearer "))throw new Response(JSON.stringify({error:"Требуется вход в аккаунт."}),{status:401});
  let userId:string;
  try{const {payload}=await jwtVerify(authorization.slice(7).trim(),jwks,{issuer});if(typeof payload.sub!=="string"||!payload.sub)throw new Error("Missing subject");userId=payload.sub;}
  catch{throw new Response(JSON.stringify({error:"Сессия недействительна. Войдите заново."}),{status:401});}
  const result=await pool.query("select exists (select 1 from public.admins where user_id = $1::uuid) as is_admin",[userId]);
  if(!result.rows[0]?.is_admin)throw new Response(JSON.stringify({error:"Недостаточно прав: операция доступна только администратору."}),{status:403});
  return userId;
}
function uploadPolicy(key:string,contentType:string){
  if(key.startsWith("testpatan-materials/")){
    const ext=key.split(".").pop()?.toLowerCase()||"";
    const allowedExt=new Set(["pdf","doc","docx","ppt","pptx","xls","xlsx","txt","rtf","odt","odp","ods"]);
    if(!allowedExt.has(ext))throw new Response(JSON.stringify({error:"Недопустимый формат документа."}),{status:415});
    const allowedMime=new Set(["application/pdf","application/msword","application/rtf","text/rtf","text/plain","application/vnd.ms-powerpoint","application/vnd.ms-excel","application/vnd.openxmlformats-officedocument.wordprocessingml.document","application/vnd.openxmlformats-officedocument.presentationml.presentation","application/vnd.openxmlformats-officedocument.spreadsheetml.sheet","application/vnd.oasis.opendocument.text","application/vnd.oasis.opendocument.presentation","application/vnd.oasis.opendocument.spreadsheet","application/octet-stream"]);
    if(!allowedMime.has(contentType.toLowerCase()))throw new Response(JSON.stringify({error:"Недопустимый MIME-тип документа."}),{status:415});
    return 25*1024*1024;
  }
  if(!/^image\/(jpeg|png|webp)$/i.test(contentType))throw new Response(JSON.stringify({error:"Разрешены только JPEG, PNG и WebP."}),{status:415});
  return 5*1024*1024;
}

type GuestRpcBody={name?:unknown;args?:Record<string,unknown>};
const guestRate=new Map<string,{window:number;count:number;starts:number;startWindow:number}>();
const UUID_RE=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const guestRpcNames=new Set(["start_attempt","check_answer","finish_attempt","get_attempt_review","resume_guest_attempt"]);
function guestError(message:string,status=400){return Response.json({data:null,error:{message}},{status});}
async function handleGuestRpc(request:Request,cors:Record<string,string>):Promise<Response>{
  const respond=(body:unknown,status=200)=>Response.json(body,{status,headers:cors});
  if(request.method!=="POST")return respond({error:"Метод не поддерживается."},405);
  const length=Number(request.headers.get("content-length")||0);
  if(length>16_384)return respond({error:"Слишком большой запрос."},413);
  let body:GuestRpcBody;
  try{body=await request.json() as GuestRpcBody;}catch{return respond({data:null,error:{message:"Некорректный JSON."}},400);}
  const name=String(body?.name||"");
  const args=body?.args&&typeof body.args==="object"&&!Array.isArray(body.args)?body.args:{};
  if(!guestRpcNames.has(name))return respond({data:null,error:{message:"Операция недоступна в гостевом режиме."}},403);

  // Best-effort per-IP throttling. The database remains protected by the narrow RPC allowlist
  // and attempt ownership checks; this bucket is an additional abuse-control layer.
  const ip=(request.headers.get("cf-connecting-ip")||request.headers.get("x-real-ip")||request.headers.get("x-forwarded-for")||"unknown").split(",")[0].trim().slice(0,100);
  const now=Date.now(),bucket=guestRate.get(ip)||{window:now,count:0,starts:0,startWindow:now};
  if(now-bucket.window>15*60_000){bucket.window=now;bucket.count=0;}
  if(now-bucket.startWindow>60*60_000){bucket.startWindow=now;bucket.starts=0;}
  bucket.count++;
  if(name==="start_attempt")bucket.starts++;
  guestRate.set(ip,bucket);
  if(ip!=="unknown"&&(bucket.count>240||bucket.starts>12))return respond({data:null,error:{message:"Слишком много гостевых запросов. Попробуйте позже."}},429);

  const client=await pool.connect();
  try{
    await client.query("BEGIN");
    // Ensure this pooled backend connection executes the existing auth.uid()-aware functions
    // in a genuinely anonymous context, never with a leftover request claim.
    await client.query("RESET request.jwt.claim.sub");
    await client.query("RESET request.jwt.claims");

    let result;
    if(name==="start_attempt"){
      const mode=String(args.p_mode||"");
      if(!["macro","micro","theory","exam"].includes(mode))throw new Error("Неверный режим.");
      const topic=args.p_topic_id==null?null:Number(args.p_topic_id);
      if(topic!==null&&(!Number.isSafeInteger(topic)||topic<=0))throw new Error("Некорректная тема.");
      const count=Math.min(Math.max(Number(args.p_count??100)||100,1),100000);
      result=await client.query("select public.start_attempt($1::text,$2::bigint,$3::integer) as data",[mode,topic,count]);
    }else if(name==="check_answer"){
      const attempt=String(args.p_attempt||""),question=String(args.p_question||""),option=String(args.p_option||"");
      if(!UUID_RE.test(attempt)||!UUID_RE.test(question)||!UUID_RE.test(option))throw new Error("Некорректные идентификаторы ответа.");
      result=await client.query("select public.check_answer($1::uuid,$2::uuid,$3::uuid) as data",[attempt,question,option]);
    }else if(name==="finish_attempt"){
      const attempt=String(args.p_attempt||"");
      if(!UUID_RE.test(attempt))throw new Error("Некорректный идентификатор попытки.");
      result=await client.query("select public.finish_attempt($1::uuid) as data",[attempt]);
    }else if(name==="get_attempt_review"){
      const attempt=String(args.p_attempt||"");
      if(!UUID_RE.test(attempt))throw new Error("Некорректный идентификатор попытки.");
      result=await client.query("select public.get_attempt_review($1::uuid) as data",[attempt]);
    }else{
      const attempt=String(args.p_attempt||"");
      if(!UUID_RE.test(attempt))throw new Error("Некорректный идентификатор попытки.");
      result=await client.query(`
        with target as (
          select id,question_count,status,
                 (select count(*)::integer from public.attempt_answers aa where aa.attempt_id=a.id and aa.chosen_option_id is not null) as answered
          from public.attempts a
          where id=$1::uuid and user_id is null
          for update
        ), changed as (
          update public.attempts a
             set status='in_progress',finished_at=null
            from target t
           where a.id=t.id and t.answered<t.question_count
          returning a.id
        )
        select exists(select 1 from changed) as data
      `,[attempt]);
      if(result.rows[0]?.data!==true)throw new Error("Гостевая попытка не найдена или уже завершена.");
    }
    await client.query("COMMIT");
    return respond({data:result.rows[0]?.data??null,error:null});
  }catch(error){
    try{await client.query("ROLLBACK");}catch{}
    const message=error instanceof Error?error.message:"Ошибка выполнения гостевой операции.";
    return respond({data:null,error:{message}},200);
  }finally{client.release();}
}

export default {async fetch(request:Request):Promise<Response>{
  const origin=request.headers.get("origin")??"";const cors=corsHeaders(origin);
  const respond=(body:unknown,status=200)=>Response.json(body,{status,headers:cors});
  if(origin&&!allowedOrigins.has(origin))return respond({error:"Origin не разрешён."},403);
  if(request.method==="OPTIONS")return new Response(null,{status:204,headers:cors});
  if(new URL(request.url).pathname.replace(/\/+$/,"").endsWith("/guest-rpc"))return handleGuestRpc(request,cors);
  if(request.method!=="POST"&&request.method!=="DELETE")return respond({error:"Метод не поддерживается."},405);
  try{
    await requireAdmin(request);
    if(request.method==="POST"){
      const key=checkedKey(request.headers.get("x-object-key"));
      const contentType=request.headers.get("content-type")??"application/octet-stream";
      const maxBytes=uploadPolicy(key,contentType);
      const bytes=new Uint8Array(await request.arrayBuffer());
      if(!bytes.byteLength)return respond({error:"Получен пустой файл."},400);
      if(bytes.byteLength>maxBytes)return respond({error:`Размер файла превышает ${Math.round(maxBytes/1024/1024)} МБ.`},413);
      await s3.send(new PutObjectCommand({Bucket:bucket,Key:key,Body:bytes,ContentType:contentType}));
      return respond({ok:true,key});
    }
    let payload:{keys?:unknown};try{payload=await request.json() as {keys?:unknown};}catch{return respond({error:"Некорректный JSON."},400);}
    const rawKeys=Array.isArray(payload?.keys)?payload.keys:[];
    if(!rawKeys.length||rawKeys.length>120)return respond({error:"Передан некорректный список файлов."},400);
    const keys=rawKeys.map(checkedKey);
    for(const key of keys)await s3.send(new DeleteObjectCommand({Bucket:bucket,Key:key}));
    return respond({ok:true,deleted:keys.length});
  }catch(error){
    if(error instanceof Response){let body:unknown={error:"Ошибка авторизации."};try{body=JSON.parse(await error.text());}catch{}return respond(body,error.status);}
    console.error("timewebs3 error",error);return respond({error:"Внутренняя ошибка при работе с Timeweb S3."},500);
  }
}};
