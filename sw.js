self.addEventListener("install",e=>self.skipWaiting());
self.addEventListener("activate",e=>e.waitUntil(self.clients.claim()));
self.addEventListener("fetch",e=>{});
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
