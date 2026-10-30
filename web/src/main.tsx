import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { SessionTokenStore, createApi } from "./api/client";
import "./styles.css";

const tokens = new SessionTokenStore();
// A refresh token that stops working clears the tokens; the app reads `isSignedIn` again on its next request.
const api = createApi({ tokens, baseUrl: import.meta.env.VITE_API_URL ?? "" });

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App api={api} />
  </StrictMode>,
);
