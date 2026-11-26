import { Head, router, usePage } from "@inertiajs/react";
import { ArrowRight, Bot, Database, KeyRound, Laptop, Lock, Shield, Sparkles } from "lucide-react";
import { useState } from "react";
import { ApiError, apiFetch } from "../../lib/api";
import type { SharedPageProps } from "../../lib/types";

interface LoginPageProps {
  auth_mode?: "solo" | "personal" | "team";
  oidc_enabled?: boolean;
}

export default function Login() {
  const { flash, auth_mode = "team", oidc_enabled = true } =
    usePage<SharedPageProps & LoginPageProps>().props;
  const [passphrase, setPassphrase] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [loginError, setLoginError] = useState<string | null>(null);

  async function handlePersonalLogin(e: React.FormEvent) {
    e.preventDefault();
    if (!passphrase) return;
    setSubmitting(true);
    setLoginError(null);
    try {
      const res = await apiFetch<{ ok: boolean; redirect_to?: string }>("/auth/personal/login", {
        method: "POST",
        body: JSON.stringify({ passphrase, return_to: "/" }),
      });
      window.location.href = res.redirect_to || "/";
    } catch (err) {
      setLoginError(
        err instanceof ApiError && err.status === 401
          ? "Invalid owner passphrase."
          : err instanceof ApiError
            ? err.message
            : "Personal sign in failed."
      );
    } finally {
      setSubmitting(false);
    }
  }

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
              <div className="flex items-center justify-between gap-2">
                <div className="flex items-center gap-2 text-sm font-semibold text-stone-900">
                  {auth_mode === "solo" ? (
                    <Laptop className="h-4 w-4 text-emerald-600" />
                  ) : auth_mode === "personal" ? (
                    <KeyRound className="h-4 w-4 text-amber-600" />
                  ) : (
                    <Shield className="h-4 w-4 text-blue-600" />
                  )}
                  {auth_mode === "solo"
                    ? "Local Solo Workspace"
                    : auth_mode === "personal"
                      ? "Personal Owner Sign-In"
                      : "Workspace Authentication"}
                </div>
                <span className="rounded-full border border-stone-200 bg-stone-50 px-2.5 py-0.5 font-mono text-[10px] uppercase tracking-wider text-stone-600">
                  {auth_mode}
                </span>
              </div>
              <p className="mt-1.5 text-sm text-stone-500">
                {auth_mode === "solo"
                  ? "Loopback-only local mode (127.0.0.1). Enter immediately with local disk storage while keeping MoDB agent grants & audit chains active."
                  : auth_mode === "personal"
                    ? "Single-owner self-hosted access without external OIDC infrastructure."
                    : "Sign in with your organization's OIDC / SSO identity provider. First verified member is provisioned as Workspace Owner."}
              </p>
            </div>

            {(flash?.alert || flash?.error || loginError) && (
              <div className="rounded-lg border border-red-200 bg-red-50 px-3.5 py-2.5 text-sm text-red-800">
                {loginError || flash?.alert || flash?.error}
              </div>
            )}
            {flash?.notice && (
              <div className="rounded-lg border border-emerald-200 bg-emerald-50 px-3.5 py-2.5 text-sm text-emerald-800">
                {flash.notice}
              </div>
            )}

            {auth_mode === "solo" ? (
              <a
                href="/auth/solo/login?return_to=/"
                onClick={(e) => {
                  e.preventDefault();
                  window.location.href = "/auth/solo/login?return_to=/";
                }}
                className="flex w-full items-center justify-center gap-2 rounded-xl bg-stone-900 px-4 py-3 text-sm font-medium text-white hover:bg-stone-800 transition"
              >
                Enter Local Workspace
                <ArrowRight className="h-4 w-4" />
              </a>
            ) : auth_mode === "personal" ? (
              <form onSubmit={(e) => void handlePersonalLogin(e)} className="space-y-3">
                <div>
                  <label className="block text-xs font-medium text-stone-700 mb-1.5">
                    Owner Passphrase
                  </label>
                  <input
                    type="password"
                    required
                    autoFocus
                    value={passphrase}
                    onChange={(e) => setPassphrase(e.target.value)}
                    placeholder="Enter VELLUM_PERSONAL_PASSPHRASE..."
                    className="w-full rounded-xl border border-stone-200 px-3.5 py-2.5 text-sm outline-none focus:border-stone-900"
                  />
                </div>
                <button
                  type="submit"
                  disabled={submitting || !passphrase}
                  className="flex w-full items-center justify-center gap-2 rounded-xl bg-stone-900 px-4 py-3 text-sm font-medium text-white hover:bg-stone-800 disabled:opacity-50 transition"
                >
                  {submitting ? "Signing in..." : "Unlock Personal Workspace"}
                  <ArrowRight className="h-4 w-4" />
                </button>
              </form>
            ) : (
              oidc_enabled && (
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
              )
            )}

            <button
              type="button"
              onClick={() => router.reload()}
              className="w-full text-center text-xs text-stone-400 hover:text-stone-600 transition"
            >
              {auth_mode === "solo"
                ? "Single .modb file · Loopback-locked · Scoped vlm_ag_ agent grants active"
                : auth_mode === "personal"
                  ? "AES-256-GCM MoDB session · Scoped vlm_ag_ agent grants active"
                  : "Zero passwords stored locally · PKCE S256 + AES-256-GCM state"}
            </button>
          </div>
        </div>
      </div>
    </>
  );
}
