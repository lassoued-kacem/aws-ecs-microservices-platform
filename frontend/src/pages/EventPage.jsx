import { useEffect, useRef, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { api, money, when } from "../api";
import { useAuth } from "../auth";
import { Stock } from "./Home";

export default function EventPage() {
  const { id } = useParams();
  const { user } = useAuth();
  const nav = useNavigate();
  const [event, setEvent] = useState(null);
  const [qty, setQty] = useState(1);
  const [state, setState] = useState({ busy: false, msg: "", ok: false });
  // One key per purchase *intent*: a double-click or network retry reuses it,
  // so the server returns the same order instead of charging twice.
  const idemKey = useRef(crypto.randomUUID());

  const load = () => api.event(id).then(setEvent).catch((e) => setState({ msg: e.message }));
  useEffect(() => { load(); }, [id]); // eslint-disable-line react-hooks/exhaustive-deps

  async function buy() {
    if (!user) return nav("/login", { state: { from: `/events/${id}` } });
    setState({ busy: true, msg: "" });
    try {
      const order = await api.buy(id, qty, idemKey.current);
      idemKey.current = crypto.randomUUID();
      setState({ ok: true, msg: `Order confirmed: ${order.quantity} ticket(s), ${money(order.total_cents)}. Tickets are being issued…` });
    } catch (e) {
      setState({ msg: e.message });
    } finally {
      load();
    }
  }

  if (!event) return <main className="page"><p className="muted">{state.msg || "Loading…"}</p></main>;
  const soldOut = event.available === 0;
  return (
    <main className="page detail">
      <div className="poster big" style={{ "--h": event.hue }}><span>{event.artist}</span></div>
      <div>
        <Link to="/" className="muted">← All events</Link>
        <h1>{event.name}</h1>
        <p className="muted">{event.venue}, {event.city} · {when(event.starts_at)}</p>
        <Stock available={event.available} capacity={event.capacity} />
        <div className="buy">
          <strong className="price">{money(event.price_cents)}</strong>
          <select value={qty} onChange={(e) => setQty(Number(e.target.value))} disabled={soldOut}>
            {[1, 2, 3, 4, 5, 6].map((n) => <option key={n} value={n}>{n} ticket{n > 1 ? "s" : ""}</option>)}
          </select>
          <button onClick={buy} disabled={state.busy || soldOut}>
            {soldOut ? "Sold out" : state.busy ? "Reserving…" : user ? "Buy now" : "Sign in to buy"}
          </button>
        </div>
        {state.msg && <p className={state.ok ? "success" : "error"}>{state.msg} {state.ok && <Link to="/me">View tickets →</Link>}</p>}
        <p className="muted small">Max 6 tickets per person. Inventory is decremented atomically in PostgreSQL, so a seat can never be sold twice.</p>
      </div>
    </main>
  );
}
