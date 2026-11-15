/* Mega Barba • Service Worker
   - Guarda o "esqueleto" do app (HTML, CSS, ícones) para abrir rápido e funcionar como app instalado.
   - NUNCA guarda dados do Supabase: agenda e horários sempre vêm ao vivo.
   - Ao publicar uma versão nova do site, troque o número em VERSAO para forçar a atualização. */
const VERSAO = "mega-barba-v7";
const ESTATICOS = ["./", "index.html", "painel.html", "tema.css", "manifest.json", "manifest-painel.json",
  "fotos/logo.png", "fotos/logo.svg", "fotos/alexsandro.webp", "fotos/wallace.webp", "fotos/fundo.jpg", "fotos/ferramentas.jpg", "icons/icon-192.png", "icons/icon-512.png"];
const CDNS = ["cdn.tailwindcss.com", "cdn.jsdelivr.net", "fonts.googleapis.com", "fonts.gstatic.com"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(VERSAO)
    .then((c) => Promise.allSettled(ESTATICOS.map((u) => c.add(u))))
    .then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys()
    .then((ks) => Promise.all(ks.filter((k) => k !== VERSAO).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.hostname.endsWith("supabase.co")) return;                       // dados: sempre rede
  if (url.origin !== location.origin && !CDNS.includes(url.hostname)) return;

  if (req.mode === "navigate") {                                          // páginas: rede primeiro, cache se offline
    e.respondWith(fetch(req).then((r) => { if (r.ok) { const c = r.clone(); caches.open(VERSAO).then((x) => x.put(req, c)); } return r; })
      .catch(() => caches.match(req).then((r) => r || caches.match("index.html"))));
    return;
  }
  e.respondWith(caches.match(req).then((hit) => {                         // arquivos: cache + atualiza em segundo plano
    const rede = fetch(req).then((r) => { if (r.ok) { const c = r.clone(); caches.open(VERSAO).then((x) => x.put(req, c)); } return r; }).catch(() => hit);
    return hit || rede;
  }));
});
