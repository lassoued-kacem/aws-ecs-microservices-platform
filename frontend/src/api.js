// Thin fetch wrapper. Cookies (HttpOnly session) are sent automatically on the
// same origin; the JS never sees the token.
async function request(path, { method = "GET", body, headers = {} } = {}) {
  const res = await fetch(path, {
    method,
    credentials: "same-origin",
    headers: { ...(body ? { "Content-Type": "application/json" } : {}), ...headers },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (res.status === 204) return null;
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const detail = Array.isArray(data.detail)
      ? data.detail.map((d) => `${d.loc?.slice(-1)[0]}: ${d.msg}`).join(", ")
      : data.detail;
    const err = new Error(detail || `Request failed (${res.status})`);
    err.status = res.status;
    throw err;
  }
  return data;
}

export const api = {
  me: () => request("/api/auth/me"),
  login: (email, password) => request("/api/auth/login", { method: "POST", body: { email, password } }),
  register: (email, display_name, password) =>
    request("/api/auth/register", { method: "POST", body: { email, display_name, password } }),
  logout: () => request("/api/auth/logout", { method: "POST" }),
  events: () => request("/api/events"),
  event: (id) => request(`/api/events/${id}`),
  buy: (event_id, quantity, idempotencyKey) =>
    request("/api/orders", {
      method: "POST",
      body: { event_id, quantity },
      headers: { "Idempotency-Key": idempotencyKey },
    }),
  orders: () => request("/api/orders"),
  tickets: () => request("/api/tickets"),
};

export const money = (cents) =>
  new Intl.NumberFormat("en-GB", { style: "currency", currency: "EUR" }).format(cents / 100);
export const when = (iso) =>
  new Date(iso).toLocaleString("en-GB", { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
