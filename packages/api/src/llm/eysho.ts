import type { LlmProvider } from "./types";

/**
 * `GET /v1/models` returns `{ data: [{ id, display_name }] }`.
 * Eysho is OpenAI-compatible, so we reuse the same catalog shape.
 */
const parseCatalog = (body: unknown): Array<{ id: string; label?: string }> => {
  if (typeof body !== "object" || body === null) return [];
  const data = (body as { data?: unknown[] }).data;
  if (!Array.isArray(data)) return [];
  return data
    .filter(
      (x): x is { id: string; display_name?: string } =>
        !!x && typeof x === "object" && typeof (x as any).id === "string",
    )
    .map((x) => ({
      id: x.id,
      label: x.display_name ?? x.id,
      source: "live",
    }));
};

/** `gpt-4o-mini` → `GPT 4o Mini`, used when the API sends no display name. */
const humanize = (id: string): string =>
  id
    .split("-")
    .map((part) =>
      /^\d/.test(part) ? part : part.charAt(0).toUpperCase() + part.slice(1),
    )
    .join(" ");

export const eysho: LlmProvider = {
  id: "eysho",
  label: "Eysho",
  order: 99,
  defaultModel: "gpt-4o-mini",
  efforts: [
    { id: "low", label: "Low" },
    { id: "medium", label: "Medium" },
    { id: "high", label: "High" },
  ],
  defaultEffort: "medium",
  catalogUrl: "https://api.eysho.info/v1/models",
  catalogHeaders: (credential, authMode) =>
    authMode === "oauth"
      ? ({} as Record<string, string>)
      : { authorization: `Bearer ${credential}` },
  parseCatalog,
  isSelectable: (id) => !!id,
  labelFor: humanize,
  fallback: ["gpt-4o-mini"],
  oauth: undefined,
};
