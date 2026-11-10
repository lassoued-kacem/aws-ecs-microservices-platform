import { useState } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { useAuth } from "../auth";

export default function Login() {
  const { login, register } = useAuth();
  const nav = useNavigate();
  const from = useLocation().state?.from || "/";
  const [mode, setMode] = useState("login");
  const [form, setForm] = useState({ email: "", name: "", password: "" });
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const set = (k) => (e) => setForm({ ...form, [k]: e.target.value });

  async function submit(e) {
    e.preventDefault();
    setBusy(true);
    setError("");
    try {
      if (mode === "login") await login(form.email, form.password);
      else await register(form.email, form.name, form.password);
      nav(from);
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="page center">
      <form className="auth" onSubmit={submit}>
        <h1>{mode === "login" ? "Welcome back" : "Create your account"}</h1>
        <label>Email<input type="email" autoComplete="email" required value={form.email} onChange={set("email")} /></label>
        {mode === "register" && (
          <label>Display name<input required maxLength={80} value={form.name} onChange={set("name")} /></label>
        )}
        <label>
          Password
          <input type="password" required minLength={mode === "register" ? 12 : 1} maxLength={128}
            autoComplete={mode === "login" ? "current-password" : "new-password"} value={form.password} onChange={set("password")} />
        </label>
        {mode === "register" && <small className="muted">At least 12 characters. A passphrase is great.</small>}
        {error && <p className="error">{error}</p>}
        <button disabled={busy}>{busy ? "…" : mode === "login" ? "Sign in" : "Create account"}</button>
        <button type="button" className="ghost" onClick={() => setMode(mode === "login" ? "register" : "login")}>
          {mode === "login" ? "New here? Create an account" : "Have an account? Sign in"}
        </button>
      </form>
    </main>
  );
}
