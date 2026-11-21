const http=require('http'),fs=require('fs'),path=require('path'),crypto=require('crypto');
const DIR=process.env.DATA_DIR||__dirname,F=path.join(DIR,'data.json'),U=path.join(DIR,'users.json');
const PORT=process.env.PORT||3000,UNLOCK=process.env.UNLOCK_PASS||'hmc';
const hash=(p,s)=>crypto.scryptSync(String(p),s,32).toString('hex');
let users;try{users=JSON.parse(fs.readFileSync(U))}catch{
 const s=crypto.randomBytes(8).toString('hex');
 users=[{u:process.env.ADMIN_USER||'admin',s,h:hash(process.env.ADMIN_PASS||'admin123',s)}];
 fs.writeFileSync(U,JSON.stringify(users))}
const sess=new Set();
const body=r=>new Promise(ok=>{let b='';r.on('data',c=>b+=c);r.on('end',()=>{try{ok(JSON.parse(b))}catch{ok({})}})});
const json=(s,c,o)=>{s.writeHead(c,{'Content-Type':'application/json'});s.end(JSON.stringify(o))};
const sid=r=>(/sid=(\w+)/.exec(r.headers.cookie||'')||[])[1];
http.createServer(async(q,s)=>{
 if(q.url==='/api/login'&&q.method==='POST'){
  const{u,p}=await body(q),x=users.find(y=>y.u===u);
  if(x&&crypto.timingSafeEqual(Buffer.from(hash(p,x.s)),Buffer.from(x.h))){
   const t=crypto.randomBytes(24).toString('hex');sess.add(t);
   s.setHeader('Set-Cookie',`sid=${t}; HttpOnly; Path=/; SameSite=Strict; Max-Age=604800`);
   return json(s,200,{ok:1})}
  return json(s,401,{ok:0})}
 if(q.url.startsWith('/api/')){
  if(!sess.has(sid(q)))return json(s,401,{});
  if(q.url==='/api/db'&&q.method==='GET'){let d={};try{d=JSON.parse(fs.readFileSync(F))}catch{}return json(s,200,d)}
  if(q.url==='/api/db'){fs.writeFileSync(F,JSON.stringify(await body(q)));return json(s,200,{ok:1})}
  if(q.url==='/api/unlock'){const{p}=await body(q);return json(s,200,{ok:p===UNLOCK})}
  if(q.url==='/api/logout'){sess.delete(sid(q));return json(s,200,{ok:1})}
  return json(s,404,{})}
 fs.readFile(path.join(__dirname,'index.html'),(e,d)=>{s.writeHead(200,{'Content-Type':'text/html; charset=utf-8'});s.end(d)});
}).listen(PORT,()=>console.log('Berjalan di port '+PORT));
