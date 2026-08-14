import { useCallback, useEffect, useState } from "react";

export function tabIdFromPathname(pathname: string): string {
  const segment = pathname.replace(/^\/+/, "").split("/")[0];
  return segment || "keymap";
}

export function pathnameFromTabId(tabId: string): string {
  return tabId === "keymap" ? "/" : `/${tabId}`;
}

export function tabIdFromLocation(location: Location): string {
  if (location.protocol === "file:") {
    return tabIdFromPathname(location.hash.replace(/^#/, ""));
  }
  return tabIdFromPathname(location.pathname);
}

/**
 * Keeps the active tab in sync with the URL path (e.g. /keymap) so tabs
 * are reachable via direct links, browser back/forward, and sharing.
 */
export function useUrlTab(): [string, (tabId: string) => void] {
  const [tabId, setTabId] = useState(() => tabIdFromLocation(window.location));

  useEffect(() => {
    const onLocationChange = () => setTabId(tabIdFromLocation(window.location));
    const eventName =
      window.location.protocol === "file:" ? "hashchange" : "popstate";
    window.addEventListener(eventName, onLocationChange);
    return () => window.removeEventListener(eventName, onLocationChange);
  }, []);

  const navigate = useCallback((nextTabId: string) => {
    const path = pathnameFromTabId(nextTabId);
    if (window.location.protocol === "file:") {
      const hash = `#${path}`;
      if (window.location.hash !== hash) window.location.hash = hash;
    } else if (window.location.pathname !== path) {
      window.history.pushState(null, "", path);
    }
    setTabId(nextTabId);
  }, []);

  return [tabId, navigate];
}
