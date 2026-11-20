self.addEventListener("install",e=>self.skipWaiting());
self.addEventListener("activate",e=>e.waitUntil(self.clients.claim()));
const C="eps-ops-v17";
self.addEventListener("activate",e=>e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!=C).map(k=>caches.delete(k))))));
self.addEventListener("fetch",e=>{
  const r=e.request;if(r.method!="GET")return;const u=new URL(r.url);
  /* bibliothèques versionnées (CDN) : cache d'abord */
  if(u.hostname=="cdn.jsdelivr.net"){e.respondWith(caches.open(C).then(c=>c.match(r).then(m=>m||fetch(r).then(x=>{if(x.ok||x.type=="opaque")c.put(r,x.clone());return x;}))));return;}
  /* page de l'app : toujours la version en ligne ; la copie en cache ne sert que hors connexion */
  if(r.mode=="navigate"&&u.origin==self.location.origin&&(u.pathname=="/"||u.pathname=="/index.html")){e.respondWith(fetch(r,{cache:"no-store"}).then(x=>{if(x.ok){const y=x.clone();caches.open(C).then(c=>c.put("/",y));}return x;}).catch(()=>caches.match("/")));return;}
  if(u.origin==self.location.origin&&/\.(png|webmanifest)$/.test(u.pathname)){e.respondWith(caches.open(C).then(c=>c.match(r).then(m=>{const n=fetch(r).then(x=>{if(x.ok)c.put(r,x.clone());return x;});return m||n;})));}
});
self.addEventListener("push",e=>{
  let d={};try{d=e.data?e.data.json():{}}catch(x){d={titre:"EPS OPS",corps:e.data?e.data.text():""}}
  const w=[self.registration.showNotification(d.titre||"EPS OPS",{body:d.corps||"",icon:"/icon-192.png",badge:"/icon-192.png",tag:d.tag||undefined,renotify:!!d.tag,data:{lien:d.lien||"",id:d.id||null}})];
  if(self.navigator&&self.navigator.setAppBadge&&d.nonlues!=null)w.push(self.navigator.setAppBadge(d.nonlues).catch(()=>{}));
  e.waitUntil(Promise.all(w));
});
self.addEventListener("notificationclick",e=>{
  e.notification.close();const d=e.notification.data||{},q=[];if(d.lien)q.push("p="+encodeURIComponent(d.lien));if(d.id)q.push("n="+d.id);
  e.waitUntil(self.clients.matchAll({type:"window",includeUncontrolled:true}).then(cs=>{
    for(const c of cs){if("focus" in c){c.postMessage({nav:d.lien,id:d.id});return c.focus();}}
    return self.clients.openWindow("/"+(q.length?"?"+q.join("&"):""));
  }));
});
