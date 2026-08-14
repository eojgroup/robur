import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react()],
  build: {
    outDir: "dist",
    // Production serves minified assets; source maps add bytes without helping users.
    sourcemap: false
  }
});
