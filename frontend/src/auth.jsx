import { createContext, useCallback, useContext, useEffect, useState } from "react";
import { api } from "./api";

const AuthCtx = createContext(null);

export function AuthProvider({ children }) {
  const [user, setUser] = useState(undefined); // undefined = loading, null = anonymous
  useEffect(() => {
    api.me().then(setUser).catch(() => setUser(null));
  }, []);
  const login = useCallback(async (e, p) => setUser(await api.login(e, p)), []);
  const register = useCallback(async (e, n, p) => setUser(await api.register(e, n, p)), []);
  const logout = useCallback(async () => {
    await api.logout().catch(() => {});
    setUser(null);
  }, []);
  return <AuthCtx.Provider value={{ user, login, register, logout }}>{children}</AuthCtx.Provider>;
}

export const useAuth = () => useContext(AuthCtx);
