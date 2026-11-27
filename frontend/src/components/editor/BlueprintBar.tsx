import { Check, ChevronDown, ChevronRight, Code, Copy, Layers, Plus, Save, Unlink } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { ApiError, apiFetch } from "../../lib/api";
import type {
  Block,
  BlueprintDef,
  CellValue,
  DatabaseDef,
  EnrichedRow,
  Page,
  PageBlueprintMeta,
  PrincipalSummary,
  PropertyDef,
  PropertyKind,
  RelationTargetOption,
} from "../../lib/types";
import InlineCellEditor from "../database/InlineCellEditor";

interface BlueprintBarProps {
  page: Page;
  blueprints: BlueprintDef[];
  pageBlueprint: BlueprintDef | null;
  pageMeta: PageBlueprintMeta | null;
  yamlFrontmatter: string;
  databases: DatabaseDef[];
  principals: PrincipalSummary[];
  relationTargets: Record<string, RelationTargetOption[]>;
  onMetaSaved: (res: {
    page: Page;
    blocks: Block[];
    page_blueprint: BlueprintDef | null;
    page_meta: PageBlueprintMeta | null;
    anchored_markdown: string;
    yaml_frontmatter: string;
  }) => void;
  onBlueprintCreated?: (bp: BlueprintDef) => void;
}

export default function BlueprintBar({
  page,
  blueprints,
  pageBlueprint,
  pageMeta,
  yamlFrontmatter,
  databases,
  principals,
  relationTargets,
  onMetaSaved,
  onBlueprintCreated,
}: BlueprintBarProps) {
  const [collapsed, setCollapsed] = useState(false);
  const [showYaml, setShowYaml] = useState(false);
  const [copiedYaml, setCopiedYaml] = useState(false);
  const [selectedBpId, setSelectedBpId] = useState<string>(pageBlueprint?.id ?? "");
  const [draftValues, setDraftValues] = useState<Record<string, CellValue>>(pageMeta?.values ?? {});
  const [applyTpl, setApplyTpl] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [showCreator, setShowCreator] = useState(false);
  const [newName, setNewName] = useState("");
  const [newSlug, setNewSlug] = useState("");
  const [newDesc, setNewDesc] = useState("");
  const [newFieldLabel, setNewFieldLabel] = useState("Status");
  const [newFieldKind, setNewFieldKind] = useState<"rich_text" | "number" | "checkbox" | "date">(
    "rich_text"
  );
  const [creatingBp, setCreatingBp] = useState(false);

  useEffect(() => {
    setSelectedBpId(pageBlueprint?.id ?? "");
    setDraftValues(pageMeta?.values ?? {});
  }, [pageBlueprint, pageMeta]);

  const activeBlueprint = useMemo(
    () =>
      blueprints.find((b) => b.id === selectedBpId) ??
      (pageBlueprint && pageBlueprint.id === selectedBpId ? pageBlueprint : null),
    [blueprints, selectedBpId, pageBlueprint]
  );

  // Synthetic wrappers so Statamic-style Blueprint fields reuse Vellum's 11-type InlineCellEditor
  const syntheticDatabase = useMemo<DatabaseDef>(() => {
    return {
      id: activeBlueprint?.id ?? "bp_synthetic",
      collection_id: page.collection_id,
      page_id: page.id,
      title: activeBlueprint?.name ?? "Blueprint",
      description: activeBlueprint?.description ?? "",
      properties: activeBlueprint?.fields ?? [],
      version: activeBlueprint?.version ?? 1,
    };
  }, [activeBlueprint, page.collection_id, page.id]);

  const syntheticRow = useMemo<EnrichedRow>(
    () => ({
      row: {
        id: page.id,
        database_id: syntheticDatabase.id,
        page_id: page.id,
        cells: draftValues,
        created_by: page.created_by,
        created_at: page.created_at,
        updated_at: page.updated_at,
        archived_at: null,
        version: page.version,
      },
      rollups: {},
    }),
    [page, syntheticDatabase.id, draftValues]
  );

  const isDirty =
    selectedBpId !== (pageBlueprint?.id ?? "") ||
    JSON.stringify(draftValues) !== JSON.stringify(pageMeta?.values ?? {});

  async function saveMeta(bpId: string | null, vals: Record<string, CellValue> | null) {
    setSaving(true);
    setError(null);
    try {
      const res = await apiFetch<{
        page: Page;
        blocks: Block[];
        page_blueprint: BlueprintDef | null;
        page_meta: PageBlueprintMeta | null;
        anchored_markdown: string;
        yaml_frontmatter: string;
      }>(`/api/pages/${page.id}/meta`, {
        method: "PUT",
        body: JSON.stringify({
          blueprint_id: bpId,
          values: vals,
          apply_template_if_empty: applyTpl,
          reason: bpId ? `Update blueprint metadata (${bpId})` : "Detach blueprint",
        }),
      });
      onMetaSaved(res);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to save blueprint metadata");
    } finally {
      setSaving(false);
    }
  }

  async function handleCreateBlueprint(e: React.FormEvent) {
    e.preventDefault();
    if (!newName.trim()) return;
    setCreatingBp(true);
    setError(null);
    try {
      const slug =
        newSlug.trim() ||
        newName
          .trim()
          .toLowerCase()
          .replace(/[^a-z0-9]+/g, "-")
          .replace(/^-|-$/g, "");
      const kindMap: Record<typeof newFieldKind, PropertyKind> = {
        rich_text: "rich_text",
        number: { number: { format: "plain" } },
        checkbox: "checkbox",
        date: { date_prop: { include_time: false } },
      };
      const fieldId =
        newFieldLabel
          .trim()
          .toLowerCase()
          .replace(/[^a-z0-9_]+/g, "_")
          .replace(/^_|_$/g, "") || "notes";
      const fields: PropertyDef[] = [
        {
          id: fieldId,
          name: newFieldLabel.trim() || "Notes",
          kind: kindMap[newFieldKind],
          required: false,
          sort_order: "a",
        },
      ];
      const created = await apiFetch<BlueprintDef>("/api/blueprints", {
        method: "POST",
        body: JSON.stringify({
          slug,
          name: newName.trim(),
          description: newDesc.trim() || null,
          icon: "layers",
          fields,
          default_template_markdown: `## ${newName.trim()} Notes\n\n`,
        }),
      });
      onBlueprintCreated?.(created);
      setSelectedBpId(created.id);
      setDraftValues({});
      setShowCreator(false);
      setNewName("");
      setNewSlug("");
      setNewDesc("");
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to create blueprint");
    } finally {
      setCreatingBp(false);
    }
  }

  if (page.kind !== "document") return null;

  return (
    <div className="rounded-xl border border-stone-200 bg-stone-50/70 overflow-hidden">
      {/* Compact Header */}
      <div className="flex flex-wrap items-center justify-between gap-2 px-4 py-2.5">
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={() => setCollapsed((v) => !v)}
            className="inline-flex items-center gap-1.5 text-xs font-semibold text-stone-800 hover:text-stone-950"
          >
            {collapsed ? (
              <ChevronRight className="h-3.5 w-3.5 text-stone-400" />
            ) : (
              <ChevronDown className="h-3.5 w-3.5 text-stone-400" />
            )}
            <Layers className="h-3.5 w-3.5 text-amber-700" />
            <span>Blueprint Metadata</span>
          </button>
          {pageBlueprint && (
            <span className="rounded-full bg-amber-100 border border-amber-200 px-2 py-0.5 text-[10px] font-medium text-amber-900">
              {pageBlueprint.name}
            </span>
          )}
          {isDirty && (
            <span className="rounded-full bg-blue-100 px-2 py-0.5 text-[10px] font-medium text-blue-800">
              Unsaved changes
            </span>
          )}
        </div>

        <div className="flex flex-wrap items-center gap-1.5">
          <select
            value={selectedBpId}
            onChange={(e) => {
              const nextId = e.target.value;
              setSelectedBpId(nextId);
              if (nextId !== pageBlueprint?.id) {
                setDraftValues({});
              } else {
                setDraftValues(pageMeta?.values ?? {});
              }
            }}
            className="rounded-lg border border-stone-200 bg-white px-2.5 py-1 text-xs text-stone-800"
          >
            <option value="">No blueprint attached</option>
            {blueprints.map((bp) => (
              <option key={bp.id} value={bp.id}>
                {bp.name} ({bp.slug})
              </option>
            ))}
          </select>

          <button
            type="button"
            onClick={() => setShowCreator((v) => !v)}
            className="inline-flex items-center gap-1 rounded-lg border border-stone-200 bg-white px-2.5 py-1 text-xs font-medium text-stone-700 hover:bg-stone-100"
          >
            <Plus className="h-3 w-3" />
            New Blueprint
          </button>

          <button
            type="button"
            onClick={() => setShowYaml((v) => !v)}
            className={`inline-flex items-center gap-1 rounded-lg border px-2.5 py-1 text-xs font-medium ${
              showYaml
                ? "border-stone-900 bg-stone-900 text-white"
                : "border-stone-200 bg-white text-stone-700 hover:bg-stone-100"
            }`}
          >
            <Code className="h-3 w-3" />
            YAML
          </button>
        </div>
      </div>

      {/* New Blueprint Form */}
      {showCreator && (
        <form
          onSubmit={(e) => void handleCreateBlueprint(e)}
          className="border-t border-stone-200 bg-white px-4 py-3 space-y-2.5"
        >
          <div className="text-xs font-semibold text-stone-800">Create Reusable Blueprint Schema</div>
          <div className="grid grid-cols-1 sm:grid-cols-4 gap-2">
            <input
              type="text"
              required
              value={newName}
              onChange={(e) => setNewName(e.target.value)}
              placeholder="Name (e.g. Decision Record)"
              className="rounded-lg border border-stone-200 px-2.5 py-1.5 text-xs outline-none focus:border-stone-500"
            />
            <input
              type="text"
              value={newSlug}
              onChange={(e) => setNewSlug(e.target.value)}
              placeholder="slug (auto if empty)"
              className="rounded-lg border border-stone-200 px-2.5 py-1.5 text-xs font-mono outline-none focus:border-stone-500"
            />
            <input
              type="text"
              value={newFieldLabel}
              onChange={(e) => setNewFieldLabel(e.target.value)}
              placeholder="First field label"
              className="rounded-lg border border-stone-200 px-2.5 py-1.5 text-xs outline-none focus:border-stone-500"
            />
            <select
              value={newFieldKind}
              onChange={(e) =>
                setNewFieldKind(e.target.value as "rich_text" | "number" | "checkbox" | "date")
              }
              className="rounded-lg border border-stone-200 bg-white px-2.5 py-1.5 text-xs"
            >
              <option value="rich_text">Rich Text Field</option>
              <option value="number">Number Field</option>
              <option value="checkbox">Checkbox Field</option>
              <option value="date">Date Field</option>
            </select>
          </div>
          <div className="flex items-center justify-between gap-2">
            <input
              type="text"
              value={newDesc}
              onChange={(e) => setNewDesc(e.target.value)}
              placeholder="Optional description..."
              className="flex-1 rounded-lg border border-stone-200 px-2.5 py-1.5 text-xs outline-none focus:border-stone-500"
            />
            <button
              type="submit"
              disabled={creatingBp || !newName.trim()}
              className="rounded-lg bg-stone-900 px-3 py-1.5 text-xs font-medium text-white hover:bg-stone-800 disabled:opacity-50"
            >
              {creatingBp ? "Creating..." : "Create Blueprint"}
            </button>
          </div>
        </form>
      )}

      {/* Body Fields */}
      {!collapsed && activeBlueprint && (
        <div className="border-t border-stone-200 bg-white px-4 py-3 space-y-3">
          {error && (
            <div className="rounded-lg border border-red-200 bg-red-50 px-3 py-1.5 text-xs text-red-800">
              {error}
            </div>
          )}

          {activeBlueprint.fields.length === 0 ? (
            <p className="text-xs text-stone-500">
              This blueprint has no custom metadata fields (template-only).
            </p>
          ) : (
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
              {activeBlueprint.fields.map((prop) => (
                <div
                  key={prop.id}
                  className="rounded-lg border border-stone-200 bg-stone-50/50 px-3 py-2 space-y-1"
                >
                  <div className="flex items-center justify-between text-[11px] font-medium text-stone-600">
                    <span>
                      {prop.name}
                      {prop.required && <span className="text-rose-600 ml-0.5">*</span>}
                    </span>
                    <span className="font-mono text-[10px] text-stone-400">{prop.id}</span>
                  </div>
                  <InlineCellEditor
                    er={syntheticRow}
                    prop={prop}
                    database={syntheticDatabase}
                    databases={databases}
                    principals={principals}
                    relationTargets={relationTargets}
                    onCommit={async (val) => {
                      setDraftValues((prev) => ({ ...prev, [prop.id]: val }));
                    }}
                  />
                </div>
              ))}
            </div>
          )}

          <div className="flex flex-wrap items-center justify-between gap-2 pt-1">
            <label className="inline-flex items-center gap-1.5 text-[11px] text-stone-600 cursor-pointer">
              <input
                type="checkbox"
                checked={applyTpl}
                onChange={(e) => setApplyTpl(e.target.checked)}
                className="rounded border-stone-300"
              />
              Populate blueprint starter template if page is empty
            </label>

            <div className="flex items-center gap-2">
              {pageBlueprint && (
                <button
                  type="button"
                  disabled={saving}
                  onClick={() => void saveMeta(null, null)}
                  className="inline-flex items-center gap-1 rounded-lg border border-stone-200 px-2.5 py-1.5 text-xs font-medium text-stone-600 hover:bg-stone-100 disabled:opacity-50"
                >
                  <Unlink className="h-3 w-3" />
                  Detach
                </button>
              )}
              <button
                type="button"
                disabled={saving}
                onClick={() => void saveMeta(activeBlueprint.id, draftValues)}
                className="inline-flex items-center gap-1 rounded-lg bg-stone-900 px-3 py-1.5 text-xs font-medium text-white hover:bg-stone-800 disabled:opacity-50"
              >
                <Save className="h-3 w-3" />
                {saving ? "Saving..." : isDirty ? "Save Metadata" : "Saved"}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* YAML Frontmatter Viewer */}
      {showYaml && (
        <div className="border-t border-stone-200 bg-stone-950 text-stone-100 px-4 py-3 space-y-2">
          <div className="flex items-center justify-between text-[11px] text-stone-400">
            <span>YAML Frontmatter + Anchored Markdown Preview</span>
            <button
              type="button"
              onClick={() => {
                void navigator.clipboard.writeText(yamlFrontmatter);
                setCopiedYaml(true);
                setTimeout(() => setCopiedYaml(false), 1500);
              }}
              className="inline-flex items-center gap-1 rounded border border-stone-700 px-2 py-0.5 text-[11px] text-stone-200 hover:bg-stone-800"
            >
              {copiedYaml ? <Check className="h-3 w-3 text-emerald-400" /> : <Copy className="h-3 w-3" />}
              {copiedYaml ? "Copied" : "Copy"}
            </button>
          </div>
          <pre className="text-[11px] font-mono leading-relaxed whitespace-pre-wrap max-h-56 overflow-y-auto text-stone-200">
            {yamlFrontmatter}
          </pre>
        </div>
      )}
    </div>
  );
}
