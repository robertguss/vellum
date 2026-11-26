import "@tiptap/react";
import "./index.css";
import { createInertiaApp } from "@inertiajs/react";
import { createRoot } from "react-dom/client";
import type { ComponentType } from "react";

type PageModule = { default: ComponentType<Record<string, unknown>> };

const pages = import.meta.glob<PageModule>("./pages/**/*.tsx", { eager: true });

createInertiaApp({
  resolve: (name) => {
    const key = `./pages/${name}.tsx`;
    const mod = pages[key];
    if (!mod) {
      throw new Error(`Inertia page not found: ${key}`);
    }
    return mod;
  },
  setup({ el, App, props }) {
    createRoot(el).render(<App {...props} />);
  },
});
