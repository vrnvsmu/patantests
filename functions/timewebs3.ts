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
export default {async fetch(request:Request):Promise<Response>{
  const origin=request.headers.get("origin")??"";const cors=corsHeaders(origin);
  const respond=(body:unknown,status=200)=>Response.json(body,{status,headers:cors});
  if(origin&&!allowedOrigins.has(origin))return respond({error:"Origin не разрешён."},403);
  if(request.method==="OPTIONS")return new Response(null,{status:204,headers:cors});
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
