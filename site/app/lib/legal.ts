/** Bump when the Terms change materially: every wallet is asked to accept again. Version date = launch date. */
export const TERMS_VERSION = process.env.NEXT_PUBLIC_TERMS_VERSION || "2026-10-26";

/** The legal entity that operates the interface, named in the Terms (set at build time). */
export const OPERATOR = process.env.NEXT_PUBLIC_OPERATOR_NAME || "the operator of Draw Shapes";

/** Where notices are sent (set at build time). */
export const CONTACT = process.env.NEXT_PUBLIC_CONTACT || "";
