import { Head, router, usePage } from "@inertiajs/react";
import { Shield, Lock, Database, Bot, ArrowRight, Sparkles } from "lucide-react";
import type { SharedPageProps } from "../../lib/types";

export default function Login() {
  const { flash } = usePage<SharedPageProps>().props;

  return (
    <>
      <Head title="Sign In — Vellum" />
      <div className="min-h-screen bg-[#faf9f6] text-stone-900 flex flex-col justify-center px-6 py-12">
        <div className="mx-auto w-full max-w-4xl grid grid-cols-1 md:grid-cols-2 gap-8 items-center">
          <div className="space-y-6">
            <div className="inline-flex items-center gap-2 rounded-full border border-stone-200 bg-white px-3 py-1 text-xs font-medium text-stone-600 shadow-xs">
              <Sparkles className="h-3.5 w-3.5 text-blue-600" />
              Pure Mo + Pure MoDB + Arvo
            </div>
            <h1 className="text-4xl font-semibold tracking-tight text-stone-950">
              Vellum
            </h1>
            <p className="text-base leading-relaxed text-stone-600">
              An open-source, AI-native collaborative workspace where humans and
              bounded agents share canonical documents, multi-view databases, and
              speculative change proposals on one crash-safe MoDB file.
            </p>
            <div className="grid grid-cols-1 gap-3 pt-2 text-sm text-stone-700">
              <div className="flex items-start gap-3">
                <Lock className="h-4 w-4 text-blue-600 mt-0.5 shrink-0" />
                <span>
                  OIDC/SSO human sessions + SHA-256 scoped{" "}
                  <code className="font-mono text-xs bg-stone-100 px-1 py-0.5 rounded">
                    vlm_ag_
                  </code>{" "}
                  agent tokens.
                </span>
              </div>
              <div className="flex items-start gap-3">
                <Database className="h-4 w-4 text-teal-700 mt-0.5 shrink-0" />
                <span>
                  Typed relational databases (Table, Board, Calendar) with exact{" "}
                  <code className="font-mono text-xs bg-stone-100 px-1 py-0.5 rounded">
                    Decimal
                  </code>{" "}
                  rollups &amp; BM25 search.
                </span>
              </div>
              <div className="flex items-start gap-3">
                <Bot className="h-4 w-4 text-amber-700 mt-0.5 shrink-0" />
                <span>
                  Advisory claims, CoW{" "}
                  <code className="font-mono text-xs bg-stone-100 px-1 py-0.5 rounded">
                    Modb.World
                  </code>{" "}
                  proposals, MCP, &amp; selective undo.
                </span>
              </div>
            </div>
          </div>

          <div className="rounded-2xl border border-stone-200 bg-white p-8 shadow-sm space-y-6">
            <div>
              <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
                <Shield className="h-4 w-4 text-blue-600" />
                Workspace Authentication
              </div>
              <p className="mt-1.5 text-sm text-stone-500">
                Sign in with your organization&apos;s OIDC / SSO identity provider.
                First verified member is provisioned as Workspace Owner.
              </p>
            </div>

            {flash?.error && (
              <div className="rounded-lg border border-red-200 bg-red-50 px-3.5 py-2.5 text-sm text-red-800">
                {flash.error}
              </div>
            )}
            {flash?.notice && (
              <div className="rounded-lg border border-emerald-200 bg-emerald-50 px-3.5 py-2.5 text-sm text-emerald-800">
                {flash.notice}
              </div>
            )}

            <a
              href="/auth/oidc/login?return_to=/"
              onClick={(e) => {
                e.preventDefault();
                window.location.href = "/auth/oidc/login?return_to=/";
              }}
              className="flex w-full items-center justify-center gap-2 rounded-xl bg-stone-900 px-4 py-3 text-sm font-medium text-white hover:bg-stone-800 transition"
            >
              Continue with OIDC SSO
              <ArrowRight className="h-4 w-4" />
            </a>

            <button
              type="button"
              onClick={() => router.reload()}
              className="w-full text-center text-xs text-stone-400 hover:text-stone-600 transition"
            >
              Zero passwords stored locally · PKCE S256 + AES-256-GCM state
            </button>
          </div>
        </div>
      </div>
    </>
  );
}
