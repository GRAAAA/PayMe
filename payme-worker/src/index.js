const RECEIPT_SCHEMA = {
  type: "object",
  properties: {
    storeName: { type: "string" },
    date: { type: "string" },
    currencyCode: { type: "string" },
    items: {
      type: "array",
      items: {
        type: "object",
        properties: {
          name: { type: "string" },
          price: { type: "number" },
          quantity: { type: "integer" },
          confidence: { type: "number" }
        },
        required: ["name", "price", "quantity", "confidence"]
      }
    },
    discounts: {
      type: "array",
      items: {
        type: "object",
        properties: {
          name: { type: "string" },
          amount: { type: "number" }
        },
        required: ["name", "amount"]
      }
    },
    tax: { type: "number" },
    rounding: { type: "number" },
    subtotal: { type: "number" },
    total: { type: "number" },
    confidence: { type: "number" },
    warnings: {
      type: "array",
      items: { type: "string" }
    },
    excludedLines: {
      type: "array",
      items: {
        type: "object",
        properties: {
          text: { type: "string" },
          reason: { type: "string" }
        },
        required: ["text", "reason"]
      }
    }
  },
  required: [
    "storeName",
    "items",
    "discounts",
    "tax",
    "rounding",
    "confidence",
    "warnings",
    "excludedLines"
  ]
};

const INSTRUCTIONS = `
Extract this receipt for a bill-splitting app.

Return JSON only. Include only real purchased items that were charged.
Do not include headers, item-count rows, subtotal, total, payment, card, QR, WiFi, cashier, invoice metadata, thank-you text, rounding, refund policy, or advertisements as items.

For each purchased item:
- name: clean readable item name
- quantity: integer quantity, default 1
- price: final line amount charged for that item after item-level quantity math
- confidence: 0.0 to 1.0

Discounts must be positive amounts in discounts[]. Do not put discounts as items.
Rounding must be reported separately and must not be treated as tax or item.
Tax/SST/GST/service charge should be tax.
Currency should be ISO code like MYR, USD, SGD when visible. Use empty string if not visible.
Confidence should reflect whether item subtotal and printed total reconcile.
If the item subtotal does not reconcile with the printed subtotal/total, lower confidence below 0.65 and explain briefly in warnings.
`;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return cors(new Response(null, { status: 204 }));
    }

    if (request.method === "GET" && url.pathname === "/health") {
      return json({ ok: true, service: "payme-receipt-proxy" });
    }

    if (request.method !== "POST" || url.pathname !== "/scan-receipt") {
      return json({ error: "Not found" }, 404);
    }

    try {
      if (!env.GEMINI_API_KEY) {
        return json({ error: "Proxy is missing GEMINI_API_KEY secret" }, 500);
      }

      const contentLength = Number(request.headers.get("content-length") || "0");
      const maxImageBytes = Number(env.MAX_IMAGE_BYTES || "1200000");
      const maxRequestBytes = maxImageBytes + 25_000;
      if (contentLength > maxRequestBytes) {
        return json({ error: "Receipt image is too large" }, 413);
      }

      const body = await request.json();
      const images = Array.isArray(body.images) ? body.images.slice(0, 1) : [];
      if (images.length === 0 || images.some((image) => typeof image !== "string" || image.length < 100)) {
        return json({ error: "Missing receipt image" }, 400);
      }

      const parts = /** @type {Array<Record<string, unknown>>} */ ([{ text: INSTRUCTIONS }]);
      for (const image of images) {
        if (base64ByteLength(image) > maxImageBytes) {
          return json({ error: "Receipt image is too large" }, 413);
        }
        parts.push({
          inline_data: {
            mime_type: "image/jpeg",
            data: image
          }
        });
      }

      const model = env.GEMINI_MODEL || "gemini-3.1-flash-lite";
      const geminiURL = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent?key=${env.GEMINI_API_KEY}`;
      const geminiResponse = await fetch(geminiURL, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          contents: [{ parts }],
          generationConfig: {
            temperature: 0,
            response_mime_type: "application/json",
            response_schema: RECEIPT_SCHEMA
          }
        })
      });

      if (!geminiResponse.ok) {
        const errorText = await geminiResponse.text();
        console.log(JSON.stringify({
          event: "gemini_error",
          status: geminiResponse.status,
          bodyPrefix: errorText.slice(0, 300)
        }));
        return json({ error: "Smart scan failed" }, 502);
      }

      const geminiJSON = await geminiResponse.json();
      const text = geminiJSON?.candidates?.[0]?.content?.parts
        ?.map((part) => part.text || "")
        .join("")
        .trim();

      if (!text) {
        return json({ error: "Smart scan returned no result" }, 502);
      }

      const receipt = JSON.parse(text);
      const safeReceipt = validateReceipt(sanitizeReceipt(receipt));
      return json(safeReceipt);
    } catch (error) {
      console.log(JSON.stringify({
        event: "proxy_exception",
        message: error instanceof Error ? error.message : String(error)
      }));
      return json({ error: "Receipt scan failed" }, 500);
    }
  }
};

function sanitizeReceipt(receipt) {
  const items = Array.isArray(receipt.items)
    ? receipt.items
        .filter((item) => typeof item?.name === "string" && Number(item.price) > 0)
        .slice(0, 120)
        .map((item) => ({
          name: cleanText(item.name).slice(0, 80),
          price: roundMoney(Number(item.price)),
          quantity: clampInt(item.quantity, 1, 99),
          confidence: clampNumber(item.confidence, 0, 1)
        }))
    : [];

  const discounts = Array.isArray(receipt.discounts)
    ? receipt.discounts
        .filter((discount) => Number(discount?.amount) > 0)
        .slice(0, 20)
        .map((discount) => ({
          name: cleanText(discount.name || "Discount").slice(0, 80),
          amount: roundMoney(Number(discount.amount))
        }))
    : [];

  return {
    storeName: cleanText(receipt.storeName || "New receipt").slice(0, 100),
    date: typeof receipt.date === "string" ? cleanText(receipt.date).slice(0, 32) : "",
    currencyCode: typeof receipt.currencyCode === "string" ? cleanText(receipt.currencyCode).slice(0, 3).toUpperCase() : "",
    items,
    discounts,
    tax: roundMoney(Math.max(0, Number(receipt.tax) || 0)),
    rounding: roundMoney(Number(receipt.rounding) || 0),
    subtotal: optionalMoney(receipt.subtotal),
    total: optionalMoney(receipt.total),
    confidence: clampNumber(receipt.confidence, 0, 1),
    warnings: Array.isArray(receipt.warnings)
      ? receipt.warnings.map((warning) => cleanText(warning).slice(0, 160)).filter(Boolean).slice(0, 10)
      : [],
    excludedLines: Array.isArray(receipt.excludedLines)
      ? receipt.excludedLines.map((line) => ({
          text: cleanText(line.text || "").slice(0, 160),
          reason: cleanText(line.reason || "Not charged").slice(0, 160)
        })).filter((line) => line.text).slice(0, 80)
      : []
  };
}

function validateReceipt(receipt) {
  const itemTotal = receipt.items.reduce((sum, item) => sum + item.price, 0);
  const discountTotal = receipt.discounts.reduce((sum, discount) => sum + discount.amount, 0);
  const expectedSubtotal = receipt.subtotal ?? null;
  const expectedTotal = receipt.total ?? null;
  const warnings = new Set(receipt.warnings);

  if (expectedSubtotal !== null) {
    const matchesSubtotal = cents(itemTotal) === cents(expectedSubtotal);
    const matchesBeforeDiscount = cents(itemTotal - discountTotal) === cents(expectedSubtotal);
    if (!matchesSubtotal && !matchesBeforeDiscount) {
      receipt.confidence = Math.min(receipt.confidence, 0.64);
      warnings.add("Item prices may not match the printed subtotal.");
    }
  }

  if (expectedTotal !== null) {
    const computedTotal = itemTotal - discountTotal + receipt.tax + receipt.rounding;
    if (Math.abs(cents(computedTotal) - cents(expectedTotal)) > 2) {
      receipt.confidence = Math.min(receipt.confidence, 0.64);
      warnings.add("Receipt total may need checking.");
    }
  }

  if (receipt.items.length === 0) {
    receipt.confidence = Math.min(receipt.confidence, 0.4);
    warnings.add("No reliable item rows were found.");
  }

  receipt.warnings = Array.from(warnings).slice(0, 10);
  return receipt;
}

function json(value, status = 200) {
  return cors(new Response(JSON.stringify(value), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff"
    }
  }));
}

function cors(response) {
  const headers = new Headers(response.headers);
  headers.set("access-control-allow-origin", "*");
  headers.set("access-control-allow-methods", "POST, OPTIONS, GET");
  headers.set("access-control-allow-headers", "content-type, authorization, x-payme-client");
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers
  });
}

function cleanText(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function roundMoney(value) {
  return Math.round((Number(value) || 0) * 100) / 100;
}

function cents(value) {
  return Math.round((Number(value) || 0) * 100);
}

function optionalMoney(value) {
  const number = Number(value);
  return Number.isFinite(number) ? roundMoney(number) : null;
}

function clampNumber(value, min, max) {
  const number = Number(value);
  if (!Number.isFinite(number)) return min;
  return Math.min(max, Math.max(min, number));
}

function clampInt(value, min, max) {
  return Math.round(clampNumber(value, min, max));
}

function base64ByteLength(base64) {
  const padding = base64.endsWith("==") ? 2 : base64.endsWith("=") ? 1 : 0;
  return Math.floor((base64.length * 3) / 4) - padding;
}
