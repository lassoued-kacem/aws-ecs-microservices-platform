import { useEffect, useState } from "react";
import { Navigate } from "react-router-dom";
import { api, money, when } from "../api";
import { useAuth } from "../auth";

export default function MyTickets() {
  const { user } = useAuth();
  const [orders, setOrders] = useState([]);
  const [tickets, setTickets] = useState([]);
  useEffect(() => {
    if (!user) return;
    const load = () => {
      api.orders().then(setOrders).catch(() => {});
      api.tickets().then(setTickets).catch(() => {});
    };
    load();
    const t = setInterval(load, 4000); // tickets arrive asynchronously (SQS -> Lambda)
    return () => clearInterval(t);
  }, [user]);

  if (user === null) return <Navigate to="/login" state={{ from: "/me" }} />;
  if (!user) return null;
  const issued = (orderId) => tickets.filter((t) => t.order_id === orderId);
  return (
    <main className="page">
      <h1>My tickets</h1>
      {orders.length === 0 && <p className="muted">No orders yet.</p>}
      {orders.map((o) => (
        <section key={o.id} className="order">
          <header>
            <h3>{o.event_name}</h3>
            <span className="muted">{when(o.created_at)} · {o.quantity} × · {money(o.total_cents)}</span>
          </header>
          <div className="tickets">
            {issued(o.id).length === 0 && <p className="muted pulse">Issuing tickets…</p>}
            {issued(o.id).map((t) => (
              <div className="ticket" key={t.ticket_id}>
                <span className="muted small">ADMIT ONE</span>
                <code>{t.seat_code}</code>
              </div>
            ))}
          </div>
        </section>
      ))}
    </main>
  );
}
