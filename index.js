async function handler(req) {
 const ip = req.headers.get('cf-connecting-ip');
 return new Response(ip, {status: 200})
}

addEventListener('fetch', event => {
 event.respondWith(handler(event.request))
})
