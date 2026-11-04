// Cloudflare Worker: ReelTunes Pro receipt email via Resend.
//
// Deploy: wrangler deploy
// Secrets: wrangler secret put RESEND_API_KEY
//
// Environment variables (wrangler.toml):
//   RESEND_API_KEY = your Resend API key (set via wrangler secret)
//   FROM_EMAIL = "ReelTunes <receipts@yourdomain.com>"  (verified domain in Resend)
//
// The Flutter app POSTs JSON to this worker:
//   {
//     "productId": "reeltunes_pro_monthly",
//     "priceString": "₹399 / month",
//     "purchasedAt": "2026-11-05T10:30:00.000Z",
//     "customerEmail": "user@example.com",
//     "expirationDate": "2026-12-05T10:30:00.000Z"
//   }

export default {
  async fetch(request, env) {
    // Only accept POST.
    if (request.method !== 'POST') {
      return new Response(JSON.stringify({ error: 'Method not allowed' }), {
        status: 405,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    // Optional: simple origin check to prevent abuse.
    // const origin = request.headers.get('Origin');
    // if (origin !== 'https://yourapp.com') return new Response('Forbidden', { status: 403 });

    let body;
    try {
      body = await request.json();
    } catch (_) {
      return new Response(JSON.stringify({ error: 'Invalid JSON' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const { productId, priceString, purchasedAt, customerEmail, expirationDate } = body;

    if (!customerEmail || !productId) {
      return new Response(JSON.stringify({ error: 'Missing required fields' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const expiresLine = expirationDate
      ? `<p><strong>Expires:</strong> ${new Date(expirationDate).toLocaleDateString()}</p>`
      : '';

    try {
      const resendResponse = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${env.RESEND_API_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          from: env.FROM_EMAIL || 'ReelTunes <receipts@yourdomain.com>',
          to: [customerEmail],
          subject: 'ReelTunes Pro — purchase receipt',
          html: `
            <h2>Thank you for subscribing to ReelTunes Pro!</h2>
            <p>Your purchase has been confirmed.</p>
            <ul>
              <li><strong>Plan:</strong> ${productId}</li>
              <li><strong>Amount:</strong> ${priceString}</li>
              <li><strong>Purchased:</strong> ${new Date(purchasedAt).toLocaleString()}</li>
              ${expiresLine}
            </ul>
            <p>Manage or cancel your subscription anytime in Google Play.</p>
          `,
        }),
      });

      if (!resendResponse.ok) {
        const errorText = await resendResponse.text();
        console.error('Resend error:', errorText);
        return new Response(JSON.stringify({ error: 'Email send failed' }), {
          status: 502,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      return new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    } catch (err) {
      console.error('Worker error:', err);
      return new Response(JSON.stringify({ error: 'Internal error' }), {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      });
    }
  },
};
