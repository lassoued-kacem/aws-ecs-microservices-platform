import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter, Link, NavLink, Route, Routes } from "react-router-dom";
import { AuthProvider, useAuth } from "./auth";
import Home from "./pages/Home";
import EventPage from "./pages/EventPage";
import Login from "./pages/Login";
import MyTickets from "./pages/MyTickets";
import "./styles.css";

function Nav() {
  const { user, logout } = useAuth();
  return (
    <header className="nav">
      <Link to="/" className="brand">
        <span className="bolt">⚡</span> TicketRush
      </Link>
      <nav>
        <NavLink to="/">Events</NavLink>
        {user && <NavLink to="/me">My tickets</NavLink>}
        {user ? (
          <button className="ghost" onClick={logout}>
            Sign out {user.display_name}
          </button>
        ) : (
          user === null && <NavLink to="/login">Sign in</NavLink>
        )}
      </nav>
    </header>
  );
}

function NotFound() {
  return (
    <main className="page center">
      <h1>404</h1>
      <p>This page sold out. <Link to="/">Back to events</Link></p>
    </main>
  );
}

createRoot(document.getElementById("root")).render(
  <StrictMode>
    <BrowserRouter>
      <AuthProvider>
        <Nav />
        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/events/:id" element={<EventPage />} />
          <Route path="/login" element={<Login />} />
          <Route path="/me" element={<MyTickets />} />
          <Route path="*" element={<NotFound />} />
        </Routes>
        <footer className="foot">
          Built on AWS: CloudFront · S3 · ALB · ECS Fargate · RDS · ElastiCache · SQS · Lambda · DynamoDB
        </footer>
      </AuthProvider>
    </BrowserRouter>
  </StrictMode>
);
