import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import "./styles.css";
import { metricColorCSS } from "@robur/core";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <style>{metricColorCSS()}</style>
    <App />
  </StrictMode>
);
