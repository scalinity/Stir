// This local ops SPA uses bearer auth; CORS grants no admin privilege.
export async function withOpsCors(
  req: Request,
  handleRequest: (req: Request) => Promise<Response>,
): Promise<Response> {
  const origin = req.headers.get('origin');
  const allowedOrigins = (Deno.env.get('STIR_OPS_ALLOWED_ORIGINS') ??
    'http://localhost:5173,http://127.0.0.1:5173').split(',').map((s) => s.trim());
  const headers = new Headers({ Vary: 'Origin' });
  if (origin && allowedOrigins.includes(origin)) {
    headers.set('Access-Control-Allow-Origin', origin);
    headers.set('Access-Control-Allow-Methods', 'POST, OPTIONS');
    headers.set(
      'Access-Control-Allow-Headers',
      'authorization, apikey, x-client-info, content-type, x-request-id',
    );
    headers.set('Access-Control-Expose-Headers', 'x-request-id');
  }
  let response: Response;
  if (req.method === 'OPTIONS') {
    response = new Response(null, {
      status: headers.has('Access-Control-Allow-Origin') ? 204 : 403,
    });
  } else {
    response = await handleRequest(req);
  }
  for (const [key, value] of headers) response.headers.set(key, value);
  return response;
}
