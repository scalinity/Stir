import { assertEquals, assertRejects } from '@std/assert';
import {
  fetchPublicRecipeText,
  isPublicAddress,
  pinnedDestination,
  requestPinned,
  resolvePublicAddresses,
} from './recipe_url_fetch.ts';

Deno.test('recipe URL blocks every private IPv6 spelling and reserved IPv4', () => {
  for (
    const address of [
      '[::1]',
      '::',
      '[fc00::1]',
      'fe80::1',
      'ff02::1',
      '::ffff:127.0.0.1',
      '[::ffff:7f00:1]',
      '::ffff:a9fe:a9fe',
      '64:ff9b::a00:1',
      '2002:a00:1::',
      '2001:db8::1',
      '192.0.2.1',
      '198.51.100.1',
      '203.0.113.1',
      '10.0.0.1',
      '127.1.2.3',
      'invalid',
    ]
  ) {
    assertEquals(isPublicAddress(address), false, address);
  }
  for (
    const address of [
      '8.8.8.8',
      '198.51.101.1',
      '203.0.114.1',
      '2606:4700:4700::1111',
      '::ffff:808:808',
    ]
  ) {
    assertEquals(isPublicAddress(address), true, address);
  }
});

Deno.test('recipe URL connects to the validated IP with original TLS and Host identity', () => {
  const options = pinnedDestination(new URL('https://recipes.example:8443/dinner?a=1'), '8.8.8.8');
  assertEquals(options.hostname, '8.8.8.8');
  assertEquals(options.tlsHostname, 'recipes.example');
  assertEquals(options.host, 'recipes.example:8443');
});

Deno.test('recipe URL rejects private literal, URL credentials, and other schemes before connecting', async () => {
  for (
    const url of [
      'http://[::1]/',
      'http://[::ffff:127.0.0.1]/',
      'http://169.254.169.254/',
      'file:///etc/passwd',
      'https://user:password@example.com/',
    ]
  ) {
    await assertRejects(() => resolvePublicAddresses(new URL(url)));
  }
});

Deno.test('recipe URL pins each DNS answer and rejects redirect to private destination', async () => {
  const requests: string[] = [];
  await assertRejects(() =>
    fetchPublicRecipeText('https://recipes.example/first', {
      resolve: async (url) =>
        url.hostname === 'recipes.example' ? ['8.8.8.8'] : await resolvePublicAddresses(url),
      request: (url, address) => {
        requests.push(url.hostname + ':' + address);
        return Promise.resolve({
          status: 302,
          location: 'http://[::ffff:7f00:1]/private',
          text: '',
        });
      },
    })
  );
  assertEquals(requests, ['recipes.example:8.8.8.8']);
});

Deno.test('recipe URL transport uses pinned local socket and preserves original Host', async () => {
  let receivedHost = '';
  const server = Deno.serve({ hostname: '127.0.0.1', port: 0, onListen() {} }, (request) => {
    receivedHost = request.headers.get('host') ?? '';
    return new Response('recipe text', { headers: { 'content-type': 'text/plain' } });
  });
  try {
    const page = await requestPinned(
      new URL('http://recipes.invalid:' + server.addr.port + '/'),
      '127.0.0.1',
      new AbortController().signal,
    );
    assertEquals(page.text, 'recipe text');
    assertEquals(receivedHost, 'recipes.invalid:' + server.addr.port);
  } finally {
    await server.shutdown();
  }
});

Deno.test('recipe URL caps the decompressed response size', async () => {
  const server = Deno.serve(
    { hostname: '127.0.0.1', port: 0, onListen() {} },
    () =>
      new Response('x'.repeat(2 * 1024 * 1024 + 1), { headers: { 'content-type': 'text/plain' } }),
  );
  try {
    await assertRejects(
      () =>
        requestPinned(
          new URL('http://recipes.invalid:' + server.addr.port),
          '127.0.0.1',
          new AbortController().signal,
        ),
      Error,
      'exceeds',
    );
  } finally {
    await server.shutdown();
  }
});

Deno.test('recipe URL decodes chunked gzip and keeps UTF8 across chunks', async () => {
  const text = 'Crème brûlée — rice. '.repeat(1000);
  const compressed = new Blob([text]).stream().pipeThrough(new CompressionStream('gzip'));
  const server = Deno.serve(
    { hostname: '127.0.0.1', port: 0, onListen() {} },
    () =>
      new Response(compressed, {
        headers: { 'content-type': 'text/plain', 'content-encoding': 'gzip' },
      }),
  );
  try {
    const page = await requestPinned(
      new URL('http://recipes.invalid:' + server.addr.port),
      '127.0.0.1',
      new AbortController().signal,
    );
    assertEquals(page.text, text);
  } finally {
    await server.shutdown();
  }
});

Deno.test('recipe URL rejects a gzip expansion beyond the body cap', async () => {
  const compressed = new Blob(['x'.repeat(2 * 1024 * 1024 + 1)]).stream().pipeThrough(
    new CompressionStream('gzip'),
  );
  const server = Deno.serve(
    { hostname: '127.0.0.1', port: 0, onListen() {} },
    () =>
      new Response(compressed, {
        headers: { 'content-type': 'text/plain', 'content-encoding': 'gzip' },
      }),
  );
  try {
    await assertRejects(
      () =>
        requestPinned(
          new URL('http://recipes.invalid:' + server.addr.port),
          '127.0.0.1',
          new AbortController().signal,
        ),
      Error,
      'exceeds',
    );
  } finally {
    await server.shutdown();
  }
});

Deno.test('recipe URL rejects an incomplete HTTP body', async () => {
  const listener = Deno.listen({ hostname: '127.0.0.1', port: 0 });
  const serving = (async () => {
    const connection = await listener.accept();
    try {
      await connection.read(new Uint8Array(2048));
      await connection.write(
        new TextEncoder().encode(
          'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 50\r\n\r\nshort',
        ),
      );
    } finally {
      connection.close();
    }
  })();
  try {
    await assertRejects(
      () =>
        requestPinned(
          new URL('http://recipes.invalid:' + listener.addr.port),
          '127.0.0.1',
          new AbortController().signal,
        ),
      Error,
      'Incomplete',
    );
  } finally {
    listener.close();
    await serving;
  }
});

Deno.test('recipe URL skips interim103/100 headers and parses the final200 body', async () => {
  const listener = Deno.listen({ hostname: '127.0.0.1', port: 0 });
  const serving = (async () => {
    const connection = await listener.accept();
    try {
      await connection.read(new Uint8Array(2048));
      const response = new TextEncoder().encode(
        'HTTP/1.1 103 Early Hints\r\nLink: </a>; rel=preload\r\n\r\n' +
          'HTTP/1.1 100 Continue\r\n\r\n' +
          'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 4\r\n\r\nrice',
      );
      let written = 0;
      while (written < response.length) {
        written += await connection.write(response.subarray(written));
      }
    } finally {
      connection.close();
    }
  })();
  try {
    const page = await requestPinned(
      new URL('http://recipes.invalid:' + listener.addr.port),
      '127.0.0.1',
      new AbortController().signal,
    );
    assertEquals(page.status, 200);
    assertEquals(page.text, 'rice');
  } finally {
    listener.close();
    await serving;
  }
});

Deno.test('recipe URL bounds interim headers and rejects incomplete or upgraded responses', async () => {
  const final = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 4\r\n\r\nrice';
  const cases = [
    ['HTTP/1.1 103 Early Hints\r\nLink: </a>\r\n\r\n', 'Invalid recipe response headers'],
    ['HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n', 'protocol upgrades'],
    [
      'HTTP/1.1 103 Early Hints\r\nX-Pad: ' + 'x'.repeat(16_384) + '\r\n\r\n' + final,
      'Invalid recipe response headers',
    ],
  ];
  for (const [raw, expected] of cases) {
    const listener = Deno.listen({ hostname: '127.0.0.1', port: 0 });
    const serving = (async () => {
      const connection = await listener.accept();
      try {
        await connection.read(new Uint8Array(2048));
        const response = new TextEncoder().encode(raw!);
        let written = 0;
        while (written < response.length) {
          written += await connection.write(response.subarray(written));
        }
      } finally {
        connection.close();
      }
    })();
    try {
      await assertRejects(
        () =>
          requestPinned(
            new URL('http://recipes.invalid:' + listener.addr.port),
            '127.0.0.1',
            new AbortController().signal,
          ),
        Error,
        expected,
      );
    } finally {
      listener.close();
      await serving;
    }
  }
});
