import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// In AWS, CloudFront routes /api/* to the ALB on the SAME origin as the SPA,
// so there is no CORS at all. Locally the Vite proxy reproduces that layout.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/api/auth": "http://localhost:8001",
      "/api": "http://localhost:8002",
    },
  },
  build: { sourcemap: false, assetsInlineLimit: 0 },
});
