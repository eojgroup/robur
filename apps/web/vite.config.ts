import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react()],
  build: {
    outDir: "dist",
    // Hosting only serves the public mock-up; source maps add bytes without helping users.
    sourcemap: false
  }
});
