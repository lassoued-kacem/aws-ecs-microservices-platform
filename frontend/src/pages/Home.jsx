import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { api, money, when } from "../api";

export function Stock({ available, capacity }) {
  const pct = capacity ? Math.round((available / capacity) * 100) : 0;
  const level = available === 0 ? "out" : pct <= 20 ? "low" : "ok";
  return (
    <div className="stock">
      <div className="bar"><span className={level} style={{ width: `${pct}%` }} /></div>
      <small className={level}>
        {available === 0 ? "Sold out" : pct <= 20 ? `Only ${available} left!` : `${available} / ${capacity} left`}
      </small>
    </div>
  );
}

export default function Home() {
  const [events, setEvents] = useState(null);
  const [error, setError] = useState("");
  useEffect(() => {
    const load = () => api.events().then(setEvents).catch((e) => setError(e.message));
    load();
    const t = setInterval(load, 10000); // live-ish stock during a drop
    return () => clearInterval(t);
  }, []);

  return (
    <main className="page">
      <section className="hero">
        <h1>Tickets drop. <span>Nobody gets oversold.</span></h1>
        <p>A flash-sale ticketing platform where every seat is sold exactly once, even when thousands click “Buy” in the same second.</p>
      </section>
      {error && <p className="error">{error}</p>}
      {!events && !error && <p className="muted">Loading events…</p>}
      <div className="grid">
        {events?.map((e) => (
          <Link to={`/events/${e.id}`} key={e.id} className="card">
            <div className="poster" style={{ "--h": e.hue }}>
              <span>{e.artist}</span>
              {e.capacity <= 20 && <em className="badge">FLASH DROP</em>}
            </div>
            <div className="card-body">
              <h3>{e.name}</h3>
              <p className="muted">{e.venue} · {e.city}</p>
              <p className="muted">{when(e.starts_at)}</p>
              <div className="row">
                <strong>{money(e.price_cents)}</strong>
                <Stock available={e.available} capacity={e.capacity} />
              </div>
            </div>
          </Link>
        ))}
      </div>
    </main>
  );
}
